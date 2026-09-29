//! `mapo attach --tab T`: the process every terminal surface runs (PROTOCOL §8, PLAN T0.6).
//! Raw mode on the local terminal, frames to the daemon, reconnect for 30 s with backoff.
//! Its stderr is the terminal screen, so it logs only to `attach.<date>.log`.

use std::io::Write as _;
use std::os::fd::AsFd;
use std::time::Duration;

use mapo_instance::Instance;
use mapo_protocol::frames::{Frame, FrameDecoder, encode_data};
use mapo_protocol::hello::{
    AttachHello, Credential, CredentialKind, HelloParams, HelloResult, Role,
};
use mapo_protocol::rpc::{Id, Incoming, Request};
use mapo_protocol::{ErrorKind, PROTOCOL_VERSION, RpcError};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::mpsc;

use super::Cli;
use crate::output::{CliError, from_instance};

#[derive(clap::Args)]
pub struct AttachArgs {
    /// The tab, by id or name.
    #[arg(long)]
    pub tab: String,
    /// Print the replay and exit after REPLAY_END, without raw mode (for checks).
    #[arg(long, hide = true)]
    pub replay_only: bool,
    /// Pretend the terminal is COLSxROWS.
    #[arg(long, hide = true)]
    pub size: Option<String>,
}

const RECONNECT_FOR: Duration = Duration::from_secs(30);
const PING_EVERY: Duration = Duration::from_secs(15);
const PONG_WITHIN: Duration = Duration::from_secs(45);

struct Size {
    cols: u16,
    rows: u16,
    width_px: u16,
    height_px: u16,
}

fn parse_size(s: &str) -> Option<Size> {
    let (c, r) = s.split_once('x')?;
    Some(Size {
        cols: c.parse().ok()?,
        rows: r.parse().ok()?,
        width_px: 0,
        height_px: 0,
    })
}

fn terminal_size(forced: &Option<String>) -> Size {
    if let Some(s) = forced.as_deref().and_then(parse_size) {
        return s;
    }
    match rustix::termios::tcgetwinsize(std::io::stdin().as_fd()) {
        Ok(ws) if ws.ws_col > 0 => Size {
            cols: ws.ws_col,
            rows: ws.ws_row,
            width_px: ws.ws_xpixel,
            height_px: ws.ws_ypixel,
        },
        _ => Size {
            cols: 80,
            rows: 24,
            width_px: 0,
            height_px: 0,
        },
    }
}

/// Puts stdin in raw mode and restores it on drop.
struct RawMode(Option<rustix::termios::Termios>);

impl RawMode {
    fn enable() -> Self {
        let stdin = std::io::stdin();
        let Ok(orig) = rustix::termios::tcgetattr(stdin.as_fd()) else {
            return Self(None);
        };
        let mut raw = orig.clone();
        raw.make_raw();
        if rustix::termios::tcsetattr(stdin.as_fd(), rustix::termios::OptionalActions::Now, &raw)
            .is_err()
        {
            return Self(None);
        }
        Self(Some(orig))
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        if let Some(orig) = &self.0 {
            let _ = rustix::termios::tcsetattr(
                std::io::stdin().as_fd(),
                rustix::termios::OptionalActions::Now,
                orig,
            );
        }
    }
}

fn log(instance: &Instance, line: &str) {
    let Ok(paths) = instance.paths() else {
        return;
    };
    let file = paths
        .log_dir
        .join(format!("attach.{}.log", crate::daemon::today()));
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(file)
    {
        let _ = writeln!(
            f,
            "{} pid={} {line}",
            crate::daemon::today(),
            std::process::id()
        );
    }
}

enum Connected {
    Attached(OwnedReadHalf, OwnedWriteHalf, Vec<u8>),
}

/// One connection attempt: hello as attach, reading `app.token` fresh (tokens rotate per boot).
async fn connect(instance: &Instance, tab: &str, size: &Size) -> Result<Connected, RpcError> {
    let paths = instance.paths().map_err(from_instance)?;
    let token = mapo_instance::read_token(&paths.token)
        .map_err(|_| RpcError::unavailable(format!("no daemon for instance {}", instance.name)))?;
    let stream = UnixStream::connect(&paths.socket)
        .await
        .map_err(|_| RpcError::unavailable(format!("no daemon for instance {}", instance.name)))?;
    let (read, mut write) = stream.into_split();
    let hello = HelloParams {
        protocol: PROTOCOL_VERSION,
        role: Role::Attach,
        client: format!("mapo-attach/{}", env!("CARGO_PKG_VERSION")),
        credential: Credential {
            kind: CredentialKind::App,
            token: token.expose().to_owned(),
        },
        attach: Some(AttachHello {
            tab: tab.to_owned(),
            workspace: None,
            cols: size.cols,
            rows: size.rows,
            width_px: size.width_px,
            height_px: size.height_px,
        }),
    };
    let req = Request::new(
        Id::Num(1),
        "hello",
        serde_json::to_value(&hello).unwrap_or_default(),
    );
    let mut line = serde_json::to_vec(&req).unwrap_or_default();
    line.push(b'\n');
    write
        .write_all(&line)
        .await
        .map_err(|e| RpcError::unavailable(format!("daemon connection lost: {e}")))?;
    let mut reader = BufReader::new(read);
    let mut resp = String::new();
    reader
        .read_line(&mut resp)
        .await
        .map_err(|e| RpcError::unavailable(format!("daemon connection lost: {e}")))?;
    let result = match Incoming::parse(resp.trim_end()) {
        Ok(Incoming::Response(r)) => r.into_result()?,
        _ => return Err(RpcError::unavailable("the daemon closed the connection")),
    };
    let hello: HelloResult = serde_json::from_value(result)
        .map_err(|e| RpcError::internal(format!("bad hello result: {e}")))?;
    if hello.instance != instance.name {
        return Err(RpcError::unavailable(format!(
            "connected to instance {} but resolved {}",
            hello.instance, instance.name
        )));
    }
    // Frames may already sit in the reader's buffer.
    let leftover = reader.buffer().to_vec();
    Ok(Connected::Attached(reader.into_inner(), write, leftover))
}

pub fn run(cli: &Cli, args: &AttachArgs) -> Result<(), CliError> {
    let instance = cli.resolve_instance()?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| CliError::internal(format!("tokio: {e}")))?;
    let code = runtime.block_on(main(instance, args));
    runtime.shutdown_background();
    std::process::exit(code);
}

async fn write_out(bytes: &[u8]) {
    let mut out = tokio::io::stdout();
    let _ = out.write_all(bytes).await;
    let _ = out.flush().await;
}

async fn main(instance: Instance, args: &AttachArgs) -> i32 {
    log(&instance, &format!("start tab={}", args.tab));
    let _raw = if args.replay_only {
        None
    } else {
        Some(RawMode::enable())
    };
    let (in_tx, mut in_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    if !args.replay_only {
        tokio::spawn(async move {
            let mut stdin = tokio::io::stdin();
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                match stdin.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if in_tx.send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }
    let mut winch =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change()).ok();
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
    let mut hup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup()).ok();
    let mut first = true;
    loop {
        // Connect, retrying for 30 s with backoff from 100 ms to 2 s.
        let deadline = tokio::time::Instant::now() + RECONNECT_FOR;
        let mut backoff = Duration::from_millis(100);
        let conn = loop {
            let size = terminal_size(&args.size);
            match connect(&instance, &args.tab, &size).await {
                Ok(c) => break Some(c),
                Err(e) if e.kind() == ErrorKind::NotFound => {
                    log(&instance, "tab closed");
                    if !first {
                        write_out(b"\r\nTab closed\r\n").await;
                    } else {
                        // PROTOCOL §4: a JSON line when stderr is piped.
                        crate::output::print_error(&e, false);
                    }
                    return if first { 1 } else { 0 };
                }
                Err(e) if e.kind() == ErrorKind::Conflict => {
                    // A stopped tab: nothing to attach to until it restarts.
                    log(&instance, &format!("not attachable: {}", e.message));
                    let msg = format!("\r\n\x1b[2m[{}]\x1b[0m\r\n", e.message);
                    write_out(msg.as_bytes()).await;
                    return 3;
                }
                Err(e) => {
                    log(&instance, &format!("connect failed: {}", e.message));
                    if tokio::time::Instant::now() >= deadline {
                        break None;
                    }
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(Duration::from_secs(2));
                }
            }
        };
        let Some(Connected::Attached(mut read, mut write, leftover)) = conn else {
            let msg = format!(
                "\r\nDisconnected from Mapo (instance {})\r\n",
                instance.name
            );
            write_out(msg.as_bytes()).await;
            log(&instance, "gave up reconnecting");
            return 2;
        };
        log(&instance, "attached");
        first = false;
        let mut decoder = FrameDecoder::new();
        decoder.push(&leftover);
        let mut buf = vec![0u8; 64 * 1024];
        let mut ping = tokio::time::interval(PING_EVERY);
        ping.tick().await;
        let mut last_pong = tokio::time::Instant::now();
        let mut replaying = false;
        'conn: loop {
            // Handle frames already buffered first.
            loop {
                match decoder.next_frame() {
                    Ok(Some(Frame::Out(bytes))) => write_out(&bytes).await,
                    Ok(Some(Frame::ReplayBegin)) => replaying = true,
                    Ok(Some(Frame::ReplayEnd)) => {
                        replaying = false;
                        if args.replay_only {
                            let _ = write.write_all(&Frame::Detach.encode()).await;
                            return 0;
                        }
                    }
                    Ok(Some(Frame::Exit(code))) => {
                        // The shell is gone; reconnecting would only replay it again. The surface
                        // shows its exit bar, and Restart (tab.restart) builds a new surface.
                        let msg = format!("\r\n\x1b[2m[shell exited with code {code}]\x1b[0m\r\n");
                        write_out(msg.as_bytes()).await;
                        log(&instance, &format!("shell exited with code {code}"));
                        return 3;
                    }
                    Ok(Some(Frame::Pong)) => last_pong = tokio::time::Instant::now(),
                    Ok(Some(Frame::Ping)) => {
                        let _ = write.write_all(&Frame::Pong.encode()).await;
                    }
                    Ok(Some(Frame::Detach)) => break 'conn,
                    Ok(Some(_)) => {}
                    Ok(None) => break,
                    Err(e) => {
                        log(&instance, &format!("bad frame: {e}"));
                        break 'conn;
                    }
                }
            }
            let _ = replaying;
            tokio::select! {
                n = read.read(&mut buf) => match n {
                    Ok(0) | Err(_) => break 'conn,
                    Ok(n) => decoder.push(&buf[..n]),
                },
                input = in_rx.recv(), if !args.replay_only => match input {
                    Some(bytes) => {
                        let mut frames = Vec::new();
                        encode_data(true, &bytes, &mut frames);
                        if write.write_all(&frames).await.is_err() {
                            break 'conn;
                        }
                    }
                    None => {
                        // stdin closed: detach in an orderly way.
                        let _ = write.write_all(&Frame::Detach.encode()).await;
                        return 0;
                    }
                },
                _ = async { match winch.as_mut() { Some(s) => { s.recv().await; } None => std::future::pending::<()>().await } } => {
                    let s = terminal_size(&args.size);
                    let f = Frame::Resize { cols: s.cols, rows: s.rows, width_px: s.width_px, height_px: s.height_px };
                    let _ = write.write_all(&f.encode()).await;
                }
                _ = ping.tick() => {
                    if last_pong.elapsed() > PONG_WITHIN {
                        log(&instance, "no pong; reconnecting");
                        break 'conn;
                    }
                    let _ = write.write_all(&Frame::Ping.encode()).await;
                }
                _ = async { match term.as_mut() { Some(s) => { s.recv().await; } None => std::future::pending::<()>().await } } => {
                    let _ = write.write_all(&Frame::Detach.encode()).await;
                    return 0;
                }
                _ = async { match hup.as_mut() { Some(s) => { s.recv().await; } None => std::future::pending::<()>().await } } => {
                    let _ = write.write_all(&Frame::Detach.encode()).await;
                    return 0;
                }
            }
        }
        if args.replay_only {
            return 1;
        }
        log(&instance, "connection lost; reconnecting");
        write_out(b"\r\n\x1b[2m[mapo] reconnecting\xe2\x80\xa6\x1b[0m").await;
    }
}
