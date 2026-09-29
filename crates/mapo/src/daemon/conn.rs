//! One connection: a reader, a writer draining an mpsc, and one task per request (PROTOCOL §1–§4).

use std::sync::Arc;

use mapo_protocol::hello::{
    Caller, CredentialKind, Empty, HelloParams, HelloResult, InstanceInfo, PingResult,
};
use mapo_protocol::rpc::{Id, Incoming, Request, Response};
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

fn encode(msg: &impl serde::Serialize) -> String {
    let mut s = serde_json::to_string(msg).unwrap_or_default();
    s.push('\n');
    s
}

pub async fn handle(shared: Arc<Shared>, stream: UnixStream) {
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::new(read);
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        while let Some(line) = rx.recv().await {
            if write.write_all(line.as_bytes()).await.is_err() {
                break;
            }
        }
        let _ = write.shutdown().await;
    });

    let session = match hello(&shared, &mut reader, &tx).await {
        Some(s) => s,
        None => {
            drop(tx);
            let _ = writer.await;
            return;
        }
    };

    let mut stop = shared.shutdown.subscribe();
    loop {
        let line = tokio::select! {
            line = read_line(&mut reader) => line,
            _ = stop.changed() => break,
        };
        match line {
            Ok(Line::Text(text)) if text.trim().is_empty() => continue,
            Ok(Line::Text(text)) => match Incoming::parse(&text) {
                Ok(Incoming::Request(req)) => {
                    let (shared, session, tx) = (shared.clone(), session.clone(), tx.clone());
                    let span = tracing::info_span!("req", id = ?req.id, method = %req.method, caller = ?session.caller.kind);
                    tokio::spawn(
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
                Ok(Incoming::Notification(_) | Incoming::Response(_)) => {}
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
    drop(tx);
    let _ = writer.await;
}

/// The first message must be `hello`; anything else is answered and the connection closed.
async fn hello(
    shared: &Shared,
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    tx: &mpsc::UnboundedSender<String>,
) -> Option<Session> {
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
    let caller = match params.credential.kind {
        CredentialKind::App if shared.token.matches(&params.credential.token) => Caller {
            kind: CredentialKind::App,
            tab_id: None,
            workspace_id: None,
        },
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
        features: vec![],
        caller: caller.clone(),
    };
    let _ = tx.send(encode(&Response::ok(
        req.id,
        serde_json::to_value(&result).unwrap_or_default(),
    )));
    Some(Session { caller })
}

async fn dispatch(shared: &Shared, session: &Session, req: Request) -> Result<Value, RpcError> {
    match req.method.as_str() {
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
            let _ = shared.shutdown.send(true);
            Ok(json!({ "stopping": true }))
        }
        methods::HELLO => Err(RpcError::invalid(
            "hello was already sent on this connection",
        )),
        other => Err(RpcError::invalid(format!("unknown method {other}"))),
    }
}

fn to_value(v: &impl serde::Serialize) -> Result<Value, RpcError> {
    serde_json::to_value(v).map_err(|e| RpcError::internal(e.to_string()))
}
