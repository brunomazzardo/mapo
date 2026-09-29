//! A tab: a login shell in a daemon-owned PTY, with an OSC pre-parser, a headless emulator, a raw
//! byte ring for replay and a text stream for waits (PLAN T0.5, ARCHITECTURE §3.4).
//!
//! One reader task owns the PTY master's read half. State lives behind a std mutex that is never
//! held across an await; waiters park on a `Notify` that fires after every chunk.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use alacritty_terminal::event::{Event as TermEvent, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::{Config as TermConfig, Term, TermMode};
use alacritty_terminal::vte::ansi::Processor;
use mapo_core::actor::{LaunchSpec, Mark as CoreMark, TabFact};
use mapo_protocol::RpcError;
use mapo_protocol::types::LaunchError;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Notify, broadcast};

use crate::env::{Resources, TabIdentity};
use crate::osc::{Fact, Mark, Preparser};
use crate::ring::Ring;
use crate::text::{Matcher, Start};

/// Reports facts to the core.
pub type FactSink = Arc<dyn Fn(&str, TabFact) + Send + Sync>;

/// Daemon-wide settings every tab shares.
pub struct HostContext {
    pub instance: String,
    pub resources: Resources,
    pub shell: String,
    pub scrollback: usize,
    pub sink: FactSink,
}

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;
const TITLE_INTERVAL: Duration = Duration::from_millis(250);
/// Without shell integration, launch commands go out after this long.
const NO_INTEGRATION_AFTER: Duration = Duration::from_secs(3);

#[derive(Clone, Copy)]
struct Size {
    cols: u16,
    rows: u16,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows as usize
    }
    fn screen_lines(&self) -> usize {
        self.rows as usize
    }
    fn columns(&self) -> usize {
        self.cols as usize
    }
}

/// Collects the emulator's replies (DA, DSR, CPR, color queries) for the tab task to write back.
#[derive(Clone, Default)]
struct Listener {
    replies: Arc<Mutex<Vec<String>>>,
}

impl EventListener for Listener {
    fn send_event(&self, event: TermEvent) {
        let reply = match event {
            TermEvent::PtyWrite(s) => Some(s),
            TermEvent::ColorRequest(index, fmt) => {
                // Mapo Glass foreground and background (UX §9) for OSC 10/11 while detached.
                let rgb = match index {
                    256 | 10 => alacritty_terminal::vte::ansi::Rgb {
                        r: 0xe6,
                        g: 0xe8,
                        b: 0xee,
                    },
                    _ => alacritty_terminal::vte::ansi::Rgb {
                        r: 0x16,
                        g: 0x18,
                        b: 0x1d,
                    },
                };
                Some(fmt(rgb))
            }
            _ => None,
        };
        if let Some(r) = reply
            && let Ok(mut v) = self.replies.lock()
        {
            v.push(r);
        }
    }
}

/// Where `tab.wait --until TEXT` and `tab.run` start matching.
#[derive(Clone)]
struct SendMark {
    text_offset: u64,
    text: String,
    /// Text offset of the 133;C that followed the send, once seen.
    command_start: Option<u64>,
}

struct State {
    preparser: Preparser,
    processor: Processor,
    term: Term<Listener>,
    listener: Listener,
    ring: Ring,
    size: Size,
    /// Any OSC 133 mark seen: shell integration is live.
    integrated: bool,
    prompt_seen: bool,
    at_prompt: bool,
    in_command: bool,
    /// An executed send waits for its prompt to go away.
    pending_exec: bool,
    last_send: Option<SendMark>,
    /// The last command's boundaries: (C offset, D offset, exit code).
    last_command: Option<(u64, Option<u64>, Option<i32>)>,
    exit: Option<i32>,
    attached: usize,
    last_title: Option<(Instant, String)>,
    pending_title: Option<String>,
}

struct Inner {
    id: String,
    state: Mutex<State>,
    changed: Notify,
    writer: tokio::sync::Mutex<Option<pty_process::OwnedWritePty>>,
    output: broadcast::Sender<Arc<[u8]>>,
    started: Instant,
    pid: Option<u32>,
}

/// A running tab.
#[derive(Clone)]
pub struct TabHandle {
    inner: Arc<Inner>,
}

/// The result of `tab.read`.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadResult {
    pub tab_id: String,
    pub text: String,
    pub alt_screen: bool,
    pub cursor: Cursor,
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
pub struct Cursor {
    pub row: usize,
    pub col: usize,
}

/// The result of `tab.run`.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunResult {
    pub exit_code: i32,
    pub output: String,
    pub truncated: bool,
    pub duration_ms: u64,
}

fn lock(inner: &Inner) -> MutexGuard<'_, State> {
    match inner.state.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn launch_error(kind: &str, message: String, path: &str) -> TabFact {
    TabFact::LaunchFailed(LaunchError {
        kind: kind.to_owned(),
        message,
        path: Some(path.to_owned()),
    })
}

/// Starts a tab's shell. Launch failures are reported to the sink and return `None`.
pub fn launch(spec: &LaunchSpec, ctx: &Arc<HostContext>) -> Option<TabHandle> {
    let sink = &ctx.sink;
    let cwd = std::path::Path::new(&spec.cwd);
    match std::fs::read_dir(cwd) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            sink(
                &spec.tab_id,
                launch_error(
                    "cwd_missing",
                    format!("The folder {} doesn't exist", spec.cwd),
                    &spec.cwd,
                ),
            );
            return None;
        }
        Err(e) => {
            sink(
                &spec.tab_id,
                launch_error(
                    "cwd_unreadable",
                    format!("Can't open {}: {e}", spec.cwd),
                    &spec.cwd,
                ),
            );
            return None;
        }
    }
    let identity = TabIdentity {
        instance: &ctx.instance,
        workspace_id: &spec.workspace_id,
        tab_id: &spec.tab_id,
        tab_name: &spec.name,
        token: &spec.token,
        hook_token: &spec.hook_token,
    };
    let env = crate::env::build(std::env::vars(), &identity, &ctx.resources);
    let spawned = (|| -> Result<(pty_process::Pty, tokio::process::Child), pty_process::Error> {
        let (pty, pts) = pty_process::open()?;
        pty.resize(pty_process::Size::new(DEFAULT_ROWS, DEFAULT_COLS))?;
        let child = pty_process::Command::new(&ctx.shell)
            .args(["-l", "-i"])
            .current_dir(cwd)
            .env_clear()
            .envs(env)
            .spawn(pts)?;
        Ok((pty, child))
    })();
    let (pty, child) = match spawned {
        Ok(p) => p,
        Err(e) => {
            sink(
                &spec.tab_id,
                launch_error(
                    "spawn_failed",
                    format!("Couldn't start {}: {e}", ctx.shell),
                    &spec.cwd,
                ),
            );
            return None;
        }
    };
    let size = Size {
        cols: DEFAULT_COLS,
        rows: DEFAULT_ROWS,
    };
    let listener = Listener::default();
    let config = TermConfig {
        scrolling_history: ctx.scrollback,
        ..TermConfig::default()
    };
    let state = State {
        preparser: Preparser::new(),
        processor: Processor::new(),
        term: Term::new(config, &size, listener.clone()),
        listener,
        ring: Ring::new(),
        size,
        integrated: false,
        prompt_seen: false,
        at_prompt: false,
        in_command: false,
        pending_exec: false,
        last_send: None,
        last_command: None,
        exit: None,
        attached: 0,
        last_title: None,
        pending_title: None,
    };
    let (read, write) = pty.into_split();
    let (output, _) = broadcast::channel(256);
    let inner = Arc::new(Inner {
        id: spec.tab_id.clone(),
        state: Mutex::new(state),
        changed: Notify::new(),
        writer: tokio::sync::Mutex::new(Some(write)),
        output,
        started: Instant::now(),
        pid: child.id(),
    });
    sink(&spec.tab_id, TabFact::Spawned);
    tokio::spawn(read_loop(
        inner.clone(),
        read,
        ctx.clone(),
        spec.command.clone(),
    ));
    tokio::spawn(wait_loop(inner.clone(), child, ctx.clone()));
    Some(TabHandle { inner })
}

async fn read_loop(
    inner: Arc<Inner>,
    mut read: pty_process::OwnedReadPty,
    ctx: Arc<HostContext>,
    command: Option<String>,
) {
    let mut buf = vec![0u8; 64 * 1024];
    let mut command = command;
    let deadline = Instant::now() + NO_INTEGRATION_AFTER;
    let mut ready_sent = false;
    loop {
        let n = tokio::select! {
            r = read.read(&mut buf) => match r {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            },
            _ = tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)), if !ready_sent => {
                ready_sent = true;
                (ctx.sink)(&inner.id, TabFact::Ready);
                if let Some(cmd) = command.take() {
                    inner_write(&inner, format!("{cmd}\r").as_bytes()).await;
                }
                continue;
            }
        };
        let chunk = &buf[..n];
        let (facts, replies, title) = process(&inner, chunk);
        let _ = inner.output.send(Arc::from(chunk));
        for r in replies {
            inner_write(&inner, r.as_bytes()).await;
        }
        for f in facts {
            if matches!(f, TabFact::Mark(CoreMark::PromptStart)) {
                ready_sent = true;
                if let Some(cmd) = command.take() {
                    inner_write(&inner, format!("{cmd}\r").as_bytes()).await;
                }
            }
            (ctx.sink)(&inner.id, f);
        }
        if let Some(t) = title {
            (ctx.sink)(&inner.id, TabFact::Title(t));
        }
        inner.changed.notify_waiters();
    }
    // Flush a throttled title.
    let pending = lock(&inner).pending_title.take();
    if let Some(t) = pending {
        (ctx.sink)(&inner.id, TabFact::Title(t));
    }
    inner.changed.notify_waiters();
}

/// Feeds one chunk through every parser. Returns core facts, emulator replies to write while no
/// client is attached, and a title to report (throttled to 4 per second).
fn process(inner: &Inner, chunk: &[u8]) -> (Vec<TabFact>, Vec<String>, Option<String>) {
    let mut st = lock(inner);
    let st = &mut *st;
    let parsed = st.preparser.advance(chunk);
    let State {
        processor, term, ..
    } = st;
    processor.advance(term, chunk);
    st.ring.push(chunk);
    let replies = match st.listener.replies.lock() {
        Ok(mut v) => std::mem::take(&mut *v),
        Err(_) => Vec::new(),
    };
    let replies = if st.attached == 0 {
        replies
    } else {
        Vec::new()
    };
    let mut facts = Vec::new();
    let mut title = None;
    for at in parsed {
        match at.fact {
            Fact::Cwd(c) => facts.push(TabFact::Cwd(c)),
            Fact::Title(t) => title = Some(t),
            Fact::Mark(m) => {
                st.integrated = true;
                let core = match m {
                    Mark::A => {
                        st.prompt_seen = true;
                        st.at_prompt = true;
                        st.in_command = false;
                        if st
                            .last_send
                            .as_ref()
                            .is_some_and(|s| s.command_start.is_none())
                        {
                            // A prompt came back without a command: an empty line or a builtin.
                        }
                        st.pending_exec = false;
                        CoreMark::PromptStart
                    }
                    Mark::B => CoreMark::PromptEnd,
                    Mark::C => {
                        st.at_prompt = false;
                        st.in_command = true;
                        st.pending_exec = false;
                        if let Some(s) = st.last_send.as_mut()
                            && s.command_start.is_none()
                        {
                            s.command_start = Some(at.text_offset);
                        }
                        st.last_command = Some((at.text_offset, None, None));
                        CoreMark::CommandStart
                    }
                    Mark::D { exit_code } => {
                        st.in_command = false;
                        if let Some((c, None, _)) = st.last_command {
                            st.last_command = Some((c, Some(at.text_offset), exit_code));
                        }
                        CoreMark::CommandEnd(exit_code)
                    }
                };
                facts.push(TabFact::Mark(core));
            }
            _ => {}
        }
    }
    if let Some(t) = title {
        let now = Instant::now();
        if st
            .last_title
            .as_ref()
            .is_none_or(|(at, _)| now.duration_since(*at) >= TITLE_INTERVAL)
        {
            st.last_title = Some((now, t.clone()));
            st.pending_title = None;
            return (facts, replies, Some(t));
        }
        st.pending_title = Some(t);
    } else if let Some((at, _)) = &st.last_title
        && Instant::now().duration_since(*at) >= TITLE_INTERVAL
        && let Some(t) = st.pending_title.take()
    {
        st.last_title = Some((Instant::now(), t.clone()));
        return (facts, replies, Some(t));
    }
    (facts, replies, None)
}

async fn inner_write(inner: &Inner, bytes: &[u8]) -> bool {
    let mut w = inner.writer.lock().await;
    match w.as_mut() {
        Some(w) => w.write_all(bytes).await.is_ok(),
        None => false,
    }
}

async fn wait_loop(inner: Arc<Inner>, mut child: tokio::process::Child, ctx: Arc<HostContext>) {
    let status = child.wait().await;
    let code = match status {
        Ok(s) => {
            use std::os::unix::process::ExitStatusExt;
            s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(0))
        }
        Err(_) => -1,
    };
    let after_prompt = {
        let mut st = lock(&inner);
        st.exit = Some(code);
        st.prompt_seen
    };
    inner.changed.notify_waiters();
    (ctx.sink)(
        &inner.id,
        TabFact::Exited {
            code,
            after_prompt,
            duration_ms: inner.started.elapsed().as_millis() as u64,
        },
    );
}

fn timeout_error(what: &str, ms: u64) -> RpcError {
    RpcError::new(
        mapo_protocol::ErrorKind::Timeout,
        format!("{what} didn't happen within {ms} ms"),
    )
}

impl TabHandle {
    pub fn id(&self) -> &str {
        &self.inner.id
    }

    /// Writes raw bytes to the PTY (attach input).
    pub async fn write(&self, bytes: &[u8]) -> bool {
        inner_write(&self.inner, bytes).await
    }

    /// `tab.send`: bracketed paste for multi-line text when the program enabled it; `execute`
    /// appends Enter. Records where waits start matching.
    pub async fn send(
        &self,
        text: &str,
        execute: bool,
        paste: Option<bool>,
    ) -> Result<usize, RpcError> {
        let mut bytes = Vec::with_capacity(text.len() + 16);
        {
            let mut st = lock(&self.inner);
            let bracketed = st.term.mode().contains(TermMode::BRACKETED_PASTE);
            let wrap = bracketed && paste.unwrap_or(text.contains('\n'));
            if wrap {
                bytes.extend_from_slice(b"\x1b[200~");
                bytes.extend_from_slice(text.as_bytes());
                bytes.extend_from_slice(b"\x1b[201~");
            } else {
                bytes.extend_from_slice(text.as_bytes());
            }
            if execute {
                bytes.push(b'\r');
            }
            let at_prompt = st.at_prompt && st.integrated;
            st.last_send = Some(SendMark {
                text_offset: st.preparser.text().end(),
                text: text.to_owned(),
                command_start: None,
            });
            if execute && at_prompt {
                st.pending_exec = true;
            }
        }
        if !self.write(&bytes).await {
            return Err(RpcError::unavailable("the tab's shell has exited"));
        }
        Ok(bytes.len())
    }

    fn is_idle(st: &State) -> bool {
        st.integrated && st.at_prompt && !st.pending_exec && !st.in_command
    }

    /// `tab.wait --until idle`: the shell sits at a prompt.
    pub async fn wait_idle(&self, timeout: Duration) -> Result<(), RpcError> {
        self.wait_for(timeout, "the prompt", |st| {
            if st.exit.is_some() {
                return Some(Err(RpcError::unavailable("the tab's shell exited")));
            }
            Self::is_idle(st).then_some(Ok(()))
        })
        .await
    }

    /// `tab.wait --until TEXT` (contract 6): matches output after the last send's command start,
    /// else after its echo, else after the wait began.
    pub async fn wait_pattern(&self, pattern: &str, timeout: Duration) -> Result<(), RpcError> {
        let began = lock(&self.inner).preparser.text().end();
        let pattern = pattern.to_owned();
        self.wait_for(timeout, &format!("\"{pattern}\""), move |st| {
            // With integration, typed-ahead text runs as a command at the next prompt: match only
            // after its 133;C, so neither the tty echo nor zle's redraw can satisfy the wait.
            let (offset, start) = match &st.last_send {
                Some(s) if st.integrated => match s.command_start {
                    Some(c) => (c, Start::AtOffset),
                    None if st.exit.is_some() => {
                        return Some(Err(RpcError::unavailable("the tab's shell exited")));
                    }
                    None => return None,
                },
                Some(s) => (s.text_offset, Start::AfterEcho(s.text.clone())),
                None => (began, Start::AtOffset),
            };
            let matched = Matcher::new(pattern.clone(), offset, start)
                .poll(st.preparser.text())
                .is_some();
            if matched {
                Some(Ok(()))
            } else if st.exit.is_some() {
                Some(Err(RpcError::unavailable("the tab's shell exited")))
            } else {
                None
            }
        })
        .await
    }

    async fn wait_for<F>(&self, timeout: Duration, what: &str, mut check: F) -> Result<(), RpcError>
    where
        F: FnMut(&State) -> Option<Result<(), RpcError>>,
    {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let notified = self.inner.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if let Some(r) = check(&lock(&self.inner)) {
                return r;
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return Err(timeout_error(what, timeout.as_millis() as u64));
            }
        }
    }

    /// `tab.read`: the last `lines` rows of scrollback and screen (contract 5).
    pub fn read(&self, lines: usize) -> ReadResult {
        let st = lock(&self.inner);
        let rows = crate::read::rows(&st.term, lines);
        let cursor = st.term.grid().cursor.point;
        ReadResult {
            tab_id: self.inner.id.clone(),
            text: rows.join("\n"),
            alt_screen: st.term.mode().contains(TermMode::ALT_SCREEN),
            cursor: Cursor {
                row: cursor.line.0.max(0) as usize,
                col: cursor.column.0,
            },
        }
    }

    /// `tab.run`: runs a command at an idle prompt and returns its output and exit code.
    pub async fn run(
        &self,
        command: &str,
        lines: usize,
        timeout: Duration,
    ) -> Result<RunResult, RpcError> {
        {
            let st = lock(&self.inner);
            if !st.integrated {
                return Err(RpcError::unavailable(
                    "tab run needs shell integration (zsh), which this tab doesn't report",
                ));
            }
            if !Self::is_idle(&st) {
                return Err(RpcError::new(
                    mapo_protocol::ErrorKind::Busy,
                    "the tab is running a command",
                )
                .with_hint("mapo tab wait NAME --until idle"));
            }
        }
        let started = Instant::now();
        self.send(command, true, Some(false)).await?;
        let mut result = None;
        self.wait_for(timeout, "the command to finish", |st| {
            let s = st.last_send.as_ref()?;
            let c = s.command_start?;
            match st.last_command {
                // Done once D arrived and the next prompt is back, so the tab is idle again.
                Some((start, Some(end), code)) if start == c && st.at_prompt => {
                    result = Some((
                        st.preparser.text().between(start, end).to_owned(),
                        code.unwrap_or(0),
                    ));
                    Some(Ok(()))
                }
                _ if st.exit.is_some() => {
                    Some(Err(RpcError::unavailable("the tab's shell exited")))
                }
                _ => None,
            }
        })
        .await?;
        let (text, exit_code) = result.unwrap_or_default();
        let (output, truncated) = last_lines(&text, lines);
        Ok(RunResult {
            exit_code,
            output,
            truncated,
            duration_ms: started.elapsed().as_millis() as u64,
        })
    }

    /// Resizes the PTY (the kernel signals the foreground job) and the emulator.
    pub async fn resize(&self, cols: u16, rows: u16, width_px: u16, height_px: u16) {
        if cols == 0 || rows == 0 {
            return;
        }
        {
            let mut st = lock(&self.inner);
            st.size = Size { cols, rows };
            let size = st.size;
            st.term.resize(size);
        }
        let w = self.inner.writer.lock().await;
        if let Some(w) = w.as_ref() {
            let _ = w.resize(pty_process::Size::new_with_pixel(
                rows, cols, width_px, height_px,
            ));
        }
    }

    /// Hangs up: dropping the master makes the kernel send SIGHUP to the session. A shell that
    /// survives 3 s gets SIGKILL.
    pub async fn close(&self) {
        let _ = self.inner.writer.lock().await.take();
        self.inner.changed.notify_waiters();
        let inner = self.inner.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(3)).await;
            if lock(&inner).exit.is_none()
                && let Some(pid) = inner
                    .pid
                    .and_then(|p| rustix::process::Pid::from_raw(p as i32))
            {
                let _ = rustix::process::kill_process(pid, rustix::process::Signal::KILL);
            }
        });
    }

    /// Whether the shell has exited.
    pub fn exited(&self) -> bool {
        lock(&self.inner).exit.is_some()
    }

    /// For attach (T0.6): the replay payload and a live receiver, taken in one step so no byte
    /// is lost or doubled between them. Raw replay falls back to grid when the ring no longer
    /// holds the switch into the alternate screen.
    pub fn attach(
        &self,
        strategy: crate::render::ReplayStrategy,
    ) -> (Vec<u8>, broadcast::Receiver<Arc<[u8]>>) {
        use crate::render::{RESET, ReplayStrategy, grid, trailer};
        let mut st = lock(&self.inner);
        st.attached += 1;
        let rx = self.inner.output.subscribe();
        let alt = st.term.mode().contains(TermMode::ALT_SCREEN);
        let trimmed_alt = alt
            && st
                .ring
                .last_alt_screen_enter()
                .is_none_or(|o| o < st.ring.start());
        let mut out = if strategy == ReplayStrategy::Grid || trimmed_alt {
            grid(&st.term, 1000)
        } else {
            let (a, b) = st.ring.contents();
            let mut v = RESET.to_vec();
            v.extend(crate::replay::strip_queries(&[a, b].concat()));
            v
        };
        out.extend(trailer(&st.term));
        (out, rx)
    }

    /// A fresh replay for a lagging client (resync), without counting a new attach.
    pub fn resync(
        &self,
        strategy: crate::render::ReplayStrategy,
    ) -> (Vec<u8>, broadcast::Receiver<Arc<[u8]>>) {
        let r = self.attach(strategy);
        self.detach();
        r
    }

    /// Resolves with the exit code once the shell exits.
    pub async fn wait_exit(&self) -> i32 {
        loop {
            let notified = self.inner.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if let Some(code) = lock(&self.inner).exit {
                return code;
            }
            notified.await;
        }
    }

    pub fn detach(&self) {
        let mut st = lock(&self.inner);
        st.attached = st.attached.saturating_sub(1);
    }
}

/// Keeps the last `lines` lines. Drops trailing blank lines and zsh's PROMPT_SP mark (a lone `%`
/// or `#` padded with spaces, printed after output that didn't end in a newline).
fn last_lines(text: &str, lines: usize) -> (String, bool) {
    let text = text.trim_start_matches(['\r', '\n']);
    let mut all: Vec<&str> = text.split('\n').collect();
    while let Some(last) = all.last() {
        let t = last.trim();
        if t.is_empty() || ((t == "%" || t == "#") && last.len() > 1) {
            all.pop();
        } else {
            break;
        }
    }
    if all.len() <= lines {
        return (all.join("\n"), false);
    }
    (all[all.len() - lines..].join("\n"), true)
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_output_trimming() {
        let cases = [
            ("hi\n%                    \n ", 200, ("hi", false)),
            ("\na\nb\nc\n", 2, ("b\nc", true)),
            ("100%\n", 200, ("100%", false)),
            ("", 200, ("", false)),
        ];
        let got: Vec<(String, bool)> = cases
            .iter()
            .map(|(t, n, _)| super::last_lines(t, *n))
            .collect();
        let want: Vec<(String, bool)> = cases
            .iter()
            .map(|(_, _, (o, tr))| ((*o).to_owned(), *tr))
            .collect();
        assert_eq!(got, want);
    }
}
