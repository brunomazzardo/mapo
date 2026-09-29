//! One connection: a reader, a writer draining an mpsc, and one task per request (PROTOCOL §1–§4).

use std::sync::Arc;

use mapo_protocol::hello::{
    Caller, CredentialKind, Empty, HelloParams, HelloResult, InstanceInfo, PingResult,
};
use mapo_protocol::rpc::{Id, Incoming, Notification, Request, Response};
use mapo_protocol::{PROTOCOL_VERSION, RpcError, methods, parse_params};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tracing::Instrument;

use super::Shared;

/// Longest accepted line (PROTOCOL: 8 MiB).
const MAX_LINE: u64 = 8 * 1024 * 1024;

/// What the daemon knows about the peer after hello.
#[derive(Debug, Clone)]
pub struct Session {
    pub caller: Caller,
    pub role: mapo_protocol::hello::Role,
}

enum Line {
    Text(String),
    Eof,
    TooLong,
}

async fn read_line<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R) -> std::io::Result<Line> {
    let mut buf = Vec::new();
    let n = (&mut *reader)
        .take(MAX_LINE + 1)
        .read_until(b'\n', &mut buf)
        .await?;
    if n == 0 {
        return Ok(Line::Eof);
    }
    if buf.last() != Some(&b'\n') && n as u64 > MAX_LINE {
        return Ok(Line::TooLong);
    }
    while matches!(buf.last(), Some(b'\n' | b'\r')) {
        buf.pop();
    }
    Ok(Line::Text(String::from_utf8_lossy(&buf).into_owned()))
}

pub(super) fn encode(msg: &impl serde::Serialize) -> Vec<u8> {
    let mut s = serde_json::to_string(msg).unwrap_or_default();
    s.push('\n');
    s.into_bytes()
}

/// Bytes queued for the connection's writer task.
/// A connection's outbound queue, counting the bytes not yet written so attach sessions can stop
/// feeding a client that fell behind and resync it instead (PROTOCOL §8).
#[derive(Clone)]
pub(super) struct Tx {
    inner: mpsc::UnboundedSender<Vec<u8>>,
    queued: Arc<std::sync::atomic::AtomicUsize>,
}

impl Tx {
    pub(super) fn send(&self, bytes: Vec<u8>) -> Result<(), ()> {
        let n = bytes.len();
        self.queued
            .fetch_add(n, std::sync::atomic::Ordering::Relaxed);
        self.inner.send(bytes).map_err(|_| {
            self.queued
                .fetch_sub(n, std::sync::atomic::Ordering::Relaxed);
        })
    }

    /// Bytes queued but not yet written to the socket.
    pub(super) fn queued(&self) -> usize {
        self.queued.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub(super) async fn closed(&self) {
        self.inner.closed().await;
    }
}

type Pending = Arc<
    std::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<Response>>>,
>;

/// A registered app connection that `ui.*` requests are forwarded to.
#[derive(Clone)]
pub struct AppRoute {
    conn: u64,
    tx: Tx,
    pending: Pending,
    next: Arc<std::sync::atomic::AtomicU64>,
}

impl AppRoute {
    /// Sends a request to the app and waits for its answer.
    async fn call(
        &self,
        method: &str,
        params: Value,
        timeout: std::time::Duration,
    ) -> Result<Value, RpcError> {
        let n = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let id = format!("d-{n}");
        let (reply, rx) = tokio::sync::oneshot::channel();
        if let Ok(mut p) = self.pending.lock() {
            p.insert(id.clone(), reply);
        }
        let req = Request::new(Id::Str(id.clone()), method, params);
        if self.tx.send(encode(&req)).is_err() {
            return Err(RpcError::unavailable("the app disconnected"));
        }
        let result = tokio::time::timeout(timeout, rx).await;
        if let Ok(mut p) = self.pending.lock() {
            p.remove(&id);
        }
        match result {
            Ok(Ok(resp)) => resp.into_result(),
            // An input that quits the app (⌘Q) did its job even though nobody is left to answer.
            Ok(Err(_)) if matches!(method, "ui.key" | "ui.click" | "ui.press") => {
                Ok(json!({ "ok": true, "appDisconnected": true }))
            }
            Ok(Err(_)) => Err(RpcError::unavailable("the app disconnected")),
            Err(_) => Err(RpcError::new(
                mapo_protocol::ErrorKind::Timeout,
                format!(
                    "the app didn't answer {method} within {} ms",
                    timeout.as_millis()
                ),
            )),
        }
    }
}

pub async fn handle(shared: Arc<Shared>, stream: UnixStream) {
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::new(read);
    let (inner_tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let queued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let tx = Tx {
        inner: inner_tx,
        queued: queued.clone(),
    };
    let writer = tokio::spawn(async move {
        while let Some(bytes) = rx.recv().await {
            let n = bytes.len();
            let ok = write.write_all(&bytes).await.is_ok();
            queued.fetch_sub(n, std::sync::atomic::Ordering::Relaxed);
            if !ok {
                break;
            }
        }
        let _ = write.shutdown().await;
    });
    // Requests in flight end with their connection (a Ctrl-C'd `tab wait` stops waiting).
    let mut requests = tokio::task::JoinSet::new();

    let session = match hello(&shared, &mut reader, &tx).await {
        Some((s, None)) => s,
        Some((s, Some(start))) => {
            super::attach::run(&shared, &s, start, &mut reader, &tx).await;
            drop(tx);
            let _ = writer.await;
            return;
        }
        None => {
            drop(tx);
            let _ = writer.await;
            return;
        }
    };

    let mut stop = shared.shutdown.subscribe();
    let mut subscribe_task: Option<tokio::task::JoinHandle<()>> = None;
    let conn_id = shared
        .next_conn
        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let pending: Pending = Arc::default();
    let watches = super::fs::Watches::default();
    loop {
        let line = tokio::select! {
            line = read_line(&mut reader) => line,
            _ = stop.changed() => break,
        };
        match line {
            Ok(Line::Text(text)) if text.trim().is_empty() => continue,
            Ok(Line::Text(text)) => match Incoming::parse(&text) {
                Ok(Incoming::Request(req)) if super::fs::is_watch(&req.method) => {
                    let _ = tx.send(encode(&super::fs::watch(&shared, &watches, req)));
                }
                Ok(Incoming::Request(req)) if req.method == methods::EVENTS_SUBSCRIBE => {
                    let (shared, tx) = (shared.clone(), tx.clone());
                    subscribe_task =
                        Some(tokio::spawn(
                            async move { subscribe(&shared, &req, &tx).await },
                        ));
                }
                Ok(Incoming::Request(req)) if req.method == "app.register" => {
                    let resp = if session.role == mapo_protocol::hello::Role::App
                        && session.caller.kind == CredentialKind::App
                    {
                        if let Ok(mut app) = shared.app.lock() {
                            *app = Some(AppRoute {
                                conn: conn_id,
                                tx: tx.clone(),
                                pending: pending.clone(),
                                next: Arc::new(std::sync::atomic::AtomicU64::new(1)),
                            });
                        }
                        tracing::info!(conn = conn_id, "app registered");
                        Response::ok(req.id, json!({}))
                    } else {
                        Response::err(
                            Some(req.id),
                            RpcError::forbidden("app.register needs the app role and credential"),
                        )
                    };
                    let _ = tx.send(encode(&resp));
                }
                Ok(Incoming::Response(resp)) => {
                    if let Some(Id::Str(id)) = &resp.id
                        && let Some(reply) = pending.lock().ok().and_then(|mut p| p.remove(id))
                    {
                        let _ = reply.send(resp);
                    }
                }
                Ok(Incoming::Request(req)) => {
                    let (shared, session, tx) = (shared.clone(), session.clone(), tx.clone());
                    let span = tracing::info_span!("req", id = ?req.id, method = %req.method, caller = ?session.caller.kind);
                    while requests.try_join_next().is_some() {}
                    requests.spawn(
                        async move {
                            let id = req.id.clone();
                            let resp = match dispatch(&shared, &session, req).await {
                                Ok(v) => Response::ok(id, v),
                                Err(e) => {
                                    tracing::info!(kind = e.kind().as_str(), "error");
                                    Response::err(Some(id), e)
                                }
                            };
                            let _ = tx.send(encode(&resp));
                        }
                        .instrument(span),
                    );
                }
                Ok(Incoming::Notification(_)) => {}
                Err((id, e)) => {
                    let _ = tx.send(encode(&Response::err(id, e)));
                }
            },
            Ok(Line::TooLong) => {
                let _ = tx.send(encode(&Response::err(
                    None,
                    RpcError::invalid("line longer than 8 MiB"),
                )));
                break;
            }
            Ok(Line::Eof) | Err(_) => break,
        }
    }
    if let Some(task) = subscribe_task {
        task.abort();
    }
    requests.abort_all();
    if let Ok(mut p) = pending.lock() {
        // Dropping the senders fails any ui.* call still waiting on this app.
        p.clear();
    }
    if session.role == mapo_protocol::hello::Role::App {
        if let Ok(mut app) = shared.app.lock()
            && app.as_ref().is_some_and(|a| a.conn == conn_id)
        {
            *app = None;
        }
        shared.core.emit("app.disconnected", json!({}));
    }
    drop(tx);
    let _ = writer.await;
}

/// An attach hello whose response the attach session sends once the tab resolves.
pub(super) struct AttachStart {
    pub id: Id,
    pub result: HelloResult,
    pub params: mapo_protocol::hello::AttachHello,
}

/// The first message must be `hello`; anything else is answered and the connection closed.
async fn hello(
    shared: &Shared,
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    tx: &Tx,
) -> Option<(Session, Option<AttachStart>)> {
    let fail = |id: Option<Id>, e: RpcError| {
        let _ = tx.send(encode(&Response::err(id, e)));
        None
    };
    let text = match read_line(reader).await {
        Ok(Line::Text(t)) => t,
        Ok(Line::TooLong) => return fail(None, RpcError::invalid("line longer than 8 MiB")),
        _ => return None,
    };
    let req: Request = match Incoming::parse(&text) {
        Ok(Incoming::Request(r)) => r,
        Ok(_) => return fail(None, RpcError::invalid("hello required")),
        Err((id, e)) => return fail(id, e),
    };
    if req.method != methods::HELLO {
        return fail(
            Some(req.id),
            RpcError::invalid("hello required: send hello before any other method"),
        );
    }
    let params: HelloParams = match parse_params(&req.params) {
        Ok(p) => p,
        Err(e) => return fail(Some(req.id), e),
    };
    if params.protocol != PROTOCOL_VERSION {
        return fail(
            Some(req.id),
            RpcError::unavailable(format!(
                "protocol {} is not supported; this daemon speaks {PROTOCOL_VERSION}",
                params.protocol
            ))
            .with_hint("restart the daemon from the same build: just kill && just app")
            .with_extra("daemonProtocol", json!(PROTOCOL_VERSION)),
        );
    }
    let tab_caller = match params.credential.kind {
        CredentialKind::Tab => shared.core.authenticate_tab(&params.credential.token).await,
        _ => None,
    };
    let caller = match params.credential.kind {
        CredentialKind::App if shared.token.matches(&params.credential.token) => Caller {
            kind: CredentialKind::App,
            tab_id: None,
            workspace_id: None,
        },
        CredentialKind::Tab if tab_caller.is_some() => tab_caller.unwrap_or(Caller {
            kind: CredentialKind::Tab,
            tab_id: None,
            workspace_id: None,
        }),
        _ => {
            return fail(
                Some(req.id),
                RpcError::forbidden("credential rejected")
                    .with_hint("the app token rotates on every daemon boot"),
            );
        }
    };
    tracing::debug!(role = ?params.role, client = %params.client, "hello");
    let result = HelloResult {
        protocol: PROTOCOL_VERSION,
        daemon: env!("CARGO_PKG_VERSION").into(),
        boot_id: shared.boot_id.clone(),
        instance: shared.instance.clone(),
        features: vec!["events".into(), "attach".into()],
        caller: caller.clone(),
        attach: None,
    };
    if params.role == mapo_protocol::hello::Role::Attach {
        if caller.kind != CredentialKind::App {
            return fail(
                Some(req.id),
                RpcError::forbidden("attach needs the app credential"),
            );
        }
        let Some(attach) = params.attach else {
            return fail(
                Some(req.id),
                RpcError::invalid("an attach hello needs params.attach"),
            );
        };
        return Some((
            Session {
                caller,
                role: params.role,
            },
            Some(AttachStart {
                id: req.id,
                result,
                params: attach,
            }),
        ));
    }
    if params.role == mapo_protocol::hello::Role::App {
        shared.core.emit("app.connected", json!({}));
    }
    let _ = tx.send(encode(&Response::ok(
        req.id,
        serde_json::to_value(&result).unwrap_or_default(),
    )));
    Some((
        Session {
            caller,
            role: params.role,
        },
        None,
    ))
}

/// Streams events after the `events.subscribe` response, until the connection or daemon ends.
async fn subscribe(shared: &Shared, req: &Request, tx: &Tx) {
    let params = match parse_params::<mapo_protocol::types::SubscribeParams>(&req.params) {
        Ok(p) => p,
        Err(e) => {
            let _ = tx.send(encode(&Response::err(Some(req.id.clone()), e)));
            return;
        }
    };
    let mut sub = match shared.core.subscribe(params).await {
        Ok(s) => s,
        Err(e) => {
            let _ = tx.send(encode(&Response::err(Some(req.id.clone()), e)));
            return;
        }
    };
    let _ = tx.send(encode(&Response::ok(
        req.id.clone(),
        json!({ "seq": sub.seq }),
    )));
    let note =
        |e: &mapo_protocol::types::Event| encode(&Notification::new(methods::EVENT, json!(e)));
    for e in &sub.replay {
        if tx.send(note(e)).is_err() {
            return;
        }
    }
    let mut stop = shared.shutdown.subscribe();
    loop {
        tokio::select! {
            item = sub.live.recv() => match item {
                Some(Ok(e)) => {
                    if tx.send(note(&e)).is_err() {
                        return;
                    }
                }
                Some(Err(e)) => {
                    let _ = tx.send(encode(&Response::err(None, e)));
                    return;
                }
                None => return,
            },
            _ = tx.closed() => return,
            _ = stop.changed() => return,
        }
    }
}

async fn dispatch(shared: &Shared, session: &Session, req: Request) -> Result<Value, RpcError> {
    if mapo_core::CoreHandle::handles(&req.method) {
        return shared
            .core
            .call(&req.method, req.params, session.caller.clone())
            .await;
    }
    if req.method == super::fs::FS_LIST {
        return super::fs::list(shared, &req).await;
    }
    if req.method.starts_with("ui.") || req.method.starts_with("explorer.") {
        // Driving the UI is the operator's: a tab token must not type into whatever has focus.
        if session.caller.kind != CredentialKind::App {
            return Err(RpcError::forbidden(format!(
                "{} needs the app credential",
                req.method
            )));
        }
        return ui(shared, &req).await;
    }
    match req.method.as_str() {
        methods::TAB_SEND
        | methods::TAB_READ
        | methods::TAB_WAIT
        | methods::TAB_RUN
        | methods::TAB_STOP => tab_io(shared, session, &req).await,
        methods::PING => {
            let _: Empty = parse_params(&req.params)?;
            to_value(&PingResult {
                boot_id: shared.boot_id.clone(),
                uptime_ms: shared.started.elapsed().as_millis() as u64,
            })
        }
        methods::INSTANCE_INFO => {
            let _: Empty = parse_params(&req.params)?;
            let p = &shared.paths;
            to_value(&InstanceInfo {
                instance: shared.instance.clone(),
                data_dir: p.data_dir.display().to_string(),
                runtime_dir: p.runtime_dir.display().to_string(),
                socket: p.socket.display().to_string(),
                daemon_pid: std::process::id(),
                version: env!("CARGO_PKG_VERSION").into(),
                protocol: PROTOCOL_VERSION,
                config_error: None,
            })
        }
        methods::DAEMON_SHUTDOWN => {
            let _: Empty = parse_params(&req.params)?;
            if session.caller.kind != CredentialKind::App {
                return Err(RpcError::forbidden(
                    "daemon.shutdown needs the app credential",
                ));
            }
            shared.stop_request.notify_one();
            Ok(json!({ "stopping": true }))
        }
        methods::HELLO => Err(RpcError::invalid(
            "hello was already sent on this connection",
        )),
        other => Err(RpcError::invalid(format!("unknown method {other}"))),
    }
}

/// Resolves the tab through the core, then acts on its live handle.
pub(super) async fn live_tab(
    shared: &Shared,
    session: &Session,
    tab: Option<String>,
    workspace: Option<String>,
) -> Result<(mapo_protocol::types::TabSummary, mapo_term::tab::TabHandle), RpcError> {
    // A tab created a moment ago may still be launching: give the host up to 5 s.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let summary = shared
            .core
            .resolve_tab(tab.clone(), workspace.clone(), session.caller.clone())
            .await?;
        if let Some(handle) = shared.host.get(&summary.id).filter(|h| !h.exited()) {
            return Ok((summary, handle));
        }
        if summary.state == mapo_protocol::types::State::Stopped {
            let code = summary.last_exit.map_or(0, |e| e.code);
            return Err(RpcError::conflict(format!(
                "tab \"{}\" stopped: its shell exited with code {code}",
                summary.name
            ))
            .with_hint(format!("mapo tab restart {}", summary.name)));
        }
        let launching = summary.state == mapo_protocol::types::State::Starting
            && summary.launch_error.is_none();
        if !launching || tokio::time::Instant::now() >= deadline {
            let why = summary
                .launch_error
                .as_ref()
                .map(|e| e.message.clone())
                .unwrap_or_else(|| "its shell isn't running".into());
            return Err(RpcError::unavailable(format!(
                "tab \"{}\" has no running shell: {why}",
                summary.name
            ))
            .with_hint(format!("mapo tab focus {}", summary.name)));
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
}

async fn tab_io(shared: &Shared, session: &Session, req: &Request) -> Result<Value, RpcError> {
    use mapo_protocol::types::{TabRead, TabRun, TabSend, TabWait, Until};
    use std::time::Duration;
    match req.method.as_str() {
        methods::TAB_SEND => {
            let p: TabSend = parse_params(&req.params)?;
            let (_, h) = live_tab(shared, session, p.tab, p.workspace).await?;
            let paste = match p.paste {
                None => None,
                Some(Value::Bool(b)) => Some(b),
                Some(Value::String(s)) if s == "auto" => None,
                Some(other) => {
                    return Err(RpcError::invalid(format!(
                        "paste must be \"auto\", true or false, not {other}"
                    )));
                }
            };
            let sent = h.send(&p.text, p.execute, paste).await?;
            Ok(json!({ "sent": sent }))
        }
        methods::TAB_STOP => {
            let p: mapo_protocol::types::TabRef = parse_params(&req.params)?;
            let (summary, h) = live_tab(shared, session, p.tab, p.workspace).await?;
            // Ctrl-C to the foreground job, as a person would press it.
            h.write(b"\x03").await;
            to_value(&summary)
        }
        methods::TAB_READ => {
            let p: TabRead = parse_params(&req.params)?;
            let (_, h) = live_tab(shared, session, p.tab, p.workspace).await?;
            to_value(&h.read(p.lines.unwrap_or(200)))
        }
        methods::TAB_WAIT => {
            let p: TabWait = parse_params(&req.params)?;
            let (_, h) = live_tab(shared, session, p.tab.clone(), p.workspace.clone()).await?;
            let timeout = Duration::from_millis(p.timeout_ms.unwrap_or(600_000));
            match &p.until {
                Until::Word(w) if w == "idle" => h.wait_idle(timeout).await?,
                Until::Word(w) => {
                    return Err(RpcError::invalid(format!(
                        "until must be \"idle\" or {{pattern}}, not {w:?}"
                    )));
                }
                Until::Pattern { pattern } => h.wait_pattern(pattern, timeout).await?,
            }
            let summary = shared
                .core
                .resolve_tab(p.tab, p.workspace, session.caller.clone())
                .await?;
            to_value(&summary)
        }
        _ => {
            let p: TabRun = parse_params(&req.params)?;
            let (_, h) = live_tab(shared, session, p.tab, p.workspace).await?;
            let timeout = Duration::from_millis(p.timeout_ms.unwrap_or(600_000));
            to_value(&h.run(&p.command, p.lines.unwrap_or(200), timeout).await?)
        }
    }
}

/// Forwards `ui.*` to the registered app; adds the daemon's own truth to snapshots and metrics.
async fn ui(shared: &Shared, req: &Request) -> Result<Value, RpcError> {
    let route = shared
        .app
        .lock()
        .ok()
        .and_then(|a| a.clone())
        .ok_or_else(|| {
            RpcError::unavailable("no app is connected to this instance").with_hint("just app")
        })?;
    let timeout = req
        .params
        .get("timeoutMs")
        .and_then(Value::as_u64)
        .map_or(std::time::Duration::from_secs(10), |ms| {
            std::time::Duration::from_millis(ms + 1000)
        });
    let mut result = route.call(&req.method, req.params.clone(), timeout).await?;
    match req.method.as_str() {
        "ui.snapshot" => {
            result["terminals"] = json!(terminals(shared).await);
        }
        "ui.metrics" => {
            let ms = shared
                .last_attach_ms
                .load(std::sync::atomic::Ordering::Relaxed);
            result["attach"] = json!({ "lastMs": if ms == 0 { Value::Null } else { json!(ms) } });
        }
        _ => {}
    }
    Ok(result)
}

/// The visible terminal panes of the active workspace, with the daemon's text (`tab read` rules).
async fn terminals(shared: &Shared) -> Vec<Value> {
    let app = Caller {
        kind: CredentialKind::App,
        tab_id: None,
        workspace_id: None,
    };
    let Ok(snapshot) = shared
        .core
        .call(methods::STATE_SNAPSHOT, json!({}), app)
        .await
    else {
        return vec![];
    };
    let tabs = snapshot["tabs"].as_array().cloned().unwrap_or_default();
    tabs.iter()
        .filter(|t| t["visible"] == json!(true))
        .filter_map(|t| {
            let id = t["id"].as_str()?;
            let handle = shared.host.get(id)?;
            Some(json!({ "tabId": id, "paneId": t["paneId"], "text": handle.read(200).text }))
        })
        .collect()
}

fn to_value(v: &impl serde::Serialize) -> Result<Value, RpcError> {
    serde_json::to_value(v).map_err(|e| RpcError::internal(e.to_string()))
}
