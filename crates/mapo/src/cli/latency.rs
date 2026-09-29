//! `mapo debug latency --tab NAME`: the keystroke proxy of ENGINEERING §6. It sends single bytes
//! through a second attach connection to a tab running `cat` and times each echo, then does the same
//! on a raw PTY it opens itself running `cat`. The p95 difference is the daemon's cost per keystroke.

use std::io::{Read as _, Write as _};
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use mapo_protocol::ErrorKind;
use mapo_protocol::frames::{Frame, FrameDecoder, encode_data};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

use super::Cli;
use super::attach::{Connected, Size, connect};
use crate::output::{CliError, print_json, wants_json};

/// How long one echo may take before the probe gives up.
const ECHO_WITHIN: Duration = Duration::from_secs(2);
/// Ctrl-U: erases the probe's bytes from `cat`'s pending line afterwards.
const KILL_LINE: u8 = 0x15;

/// The byte for sample `i`: letters, so `cat` echoes each one as itself.
fn probe_byte(i: usize) -> u8 {
    b'a' + (i % 26) as u8
}

pub fn run(cli: &Cli, tab: &str, count: usize) -> Result<(), CliError> {
    if !(1..=10_000).contains(&count) {
        return Err(CliError::invalid("--count must be from 1 to 10000"));
    }
    let instance = cli.resolve_instance()?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| CliError::internal(format!("tokio: {e}")))?;
    let attach = runtime.block_on(attach_probe(
        &instance,
        tab,
        cli.workspace.as_deref(),
        count,
    ));
    runtime.shutdown_background();
    let attach = attach?;
    let raw = pty_probe(count)?;
    let (a, r) = (Stats::of(attach), Stats::of(raw));
    let out = json!({
        "tab": tab,
        "samples": count,
        "attach": a.json(),
        "rawPty": r.json(),
        "p50DiffMs": round(a.p50 - r.p50),
        "p95DiffMs": round(a.p95 - r.p95),
    });
    if wants_json(cli.json) {
        print_json(&out, true);
    } else {
        println!(
            "{:<9}{:>9}{:>9}{:>9}",
            "PROBE", "P50 MS", "P95 MS", "MAX MS"
        );
        for (name, s) in [("attach", &a), ("raw pty", &r)] {
            println!("{name:<9}{:>9.3}{:>9.3}{:>9.3}", s.p50, s.p95, s.max);
        }
        println!(
            "p95 difference: {:+.3} ms over {count} bytes",
            a.p95 - r.p95
        );
    }
    Ok(())
}

struct Stats {
    p50: f64,
    p95: f64,
    max: f64,
}

impl Stats {
    fn of(mut ms: Vec<f64>) -> Self {
        ms.sort_by(f64::total_cmp);
        let at = |q: f64| ms[((ms.len() as f64 * q).ceil() as usize).clamp(1, ms.len()) - 1];
        Self {
            p50: at(0.5),
            p95: at(0.95),
            max: ms.last().copied().unwrap_or_default(),
        }
    }

    fn json(&self) -> Value {
        json!({ "p50Ms": round(self.p50), "p95Ms": round(self.p95), "maxMs": round(self.max) })
    }
}

fn round(ms: f64) -> f64 {
    (ms * 1000.0).round() / 1000.0
}

fn probe_error(what: &str, detail: impl std::fmt::Display) -> CliError {
    CliError::unavailable(format!("latency probe: {what}: {detail}"))
}

/// Times `count` single-byte echoes through a second attach client. It attaches at 0×0, which the
/// daemon takes as "keep the current size", so the app's surface isn't resized under it.
async fn attach_probe(
    instance: &mapo_instance::Instance,
    tab: &str,
    workspace: Option<&str>,
    count: usize,
) -> Result<Vec<f64>, CliError> {
    let size = Size {
        cols: 0,
        rows: 0,
        width_px: 0,
        height_px: 0,
    };
    let Connected::Attached(mut read, mut write, leftover) =
        connect(instance, tab, workspace, &size).await?;
    let mut decoder = FrameDecoder::new();
    decoder.push(&leftover);
    let mut buf = vec![0u8; 64 * 1024];
    // Skip the replay: the echo of a byte must not match text already on the screen.
    let mut replayed = false;
    while !replayed {
        match decoder.next_frame() {
            Ok(Some(Frame::ReplayEnd)) => replayed = true,
            Ok(Some(Frame::Exit(code))) => {
                return Err(probe_error("the tab exited", format!("code {code}")));
            }
            Ok(Some(_)) => {}
            Ok(None) => {
                let n = tokio::time::timeout(ECHO_WITHIN, read.read(&mut buf))
                    .await
                    .map_err(|_| probe_error("attach", "no replay within 2 s"))?
                    .map_err(|e| probe_error("attach", e))?;
                if n == 0 {
                    return Err(probe_error("attach", "the daemon closed the connection"));
                }
                decoder.push(&buf[..n]);
            }
            Err(e) => return Err(probe_error("attach", e)),
        }
    }
    let mut samples = Vec::with_capacity(count);
    for i in 0..count {
        let byte = probe_byte(i);
        let mut frame = Vec::new();
        encode_data(true, &[byte], &mut frame);
        let started = Instant::now();
        write
            .write_all(&frame)
            .await
            .map_err(|e| probe_error("attach write", e))?;
        'echo: loop {
            while let Some(f) = decoder.next_frame().map_err(|e| probe_error("attach", e))? {
                match f {
                    Frame::Out(bytes) if bytes.contains(&byte) => break 'echo,
                    Frame::Exit(code) => {
                        return Err(probe_error("the tab exited", format!("code {code}")));
                    }
                    _ => {}
                }
            }
            let left = ECHO_WITHIN.saturating_sub(started.elapsed());
            let n = tokio::time::timeout(left, read.read(&mut buf))
                .await
                .map_err(|_| {
                    CliError::new(
                        ErrorKind::Timeout,
                        format!("latency probe: tab {tab} didn't echo a byte within 2 s"),
                    )
                    .with_hint(format!("Run cat in it first: mapo tab send {tab} cat"))
                })?
                .map_err(|e| probe_error("attach read", e))?;
            if n == 0 {
                return Err(probe_error("attach", "the daemon closed the connection"));
            }
            decoder.push(&buf[..n]);
        }
        samples.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    let mut tail = Vec::new();
    encode_data(true, &[KILL_LINE], &mut tail);
    Frame::Detach.encode_into(&mut tail);
    let _ = write.write_all(&tail).await;
    Ok(samples)
}

/// Times `count` single-byte echoes on a PTY this process opens, with `cat` on its other end.
fn pty_probe(count: usize) -> Result<Vec<f64>, CliError> {
    let (master, slave) = open_pty().map_err(|e| probe_error("openpty", e))?;
    let mut cat = Command::new("cat")
        .stdin(Stdio::from(
            slave.try_clone().map_err(|e| probe_error("pty", e))?,
        ))
        .stdout(Stdio::from(
            slave.try_clone().map_err(|e| probe_error("pty", e))?,
        ))
        .stderr(Stdio::from(slave))
        .spawn()
        .map_err(|e| probe_error("spawn cat", e))?;
    let mut pty = std::fs::File::from(master);
    let result = (|| {
        let mut samples = Vec::with_capacity(count);
        let mut buf = [0u8; 4096];
        for i in 0..count {
            let byte = probe_byte(i);
            let started = Instant::now();
            pty.write_all(&[byte])
                .map_err(|e| probe_error("pty write", e))?;
            loop {
                let left = ECHO_WITHIN.saturating_sub(started.elapsed());
                if !readable(&pty, left) {
                    return Err(probe_error("pty", "no echo within 2 s"));
                }
                let n = pty.read(&mut buf).map_err(|e| probe_error("pty read", e))?;
                if buf[..n].contains(&byte) {
                    break;
                }
            }
            samples.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        Ok(samples)
    })();
    let _ = cat.kill();
    let _ = cat.wait();
    result
}

/// A fresh PTY pair: (master, slave).
#[allow(unsafe_code)]
fn open_pty() -> std::io::Result<(OwnedFd, OwnedFd)> {
    let (mut master, mut slave) = (-1, -1);
    // SAFETY: openpty writes two new descriptors into the ints we own; the name, termios and
    // window size pointers may be null.
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: openpty succeeded, so both descriptors are open and nothing else owns them.
    Ok(unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) })
}

/// Waits up to `within` for `file` to have bytes to read.
#[allow(unsafe_code)]
fn readable(file: &std::fs::File, within: Duration) -> bool {
    let mut fds = libc::pollfd {
        fd: file.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    let ms = i32::try_from(within.as_millis()).unwrap_or(i32::MAX);
    // SAFETY: one pollfd we own, for a descriptor that stays open for the call.
    unsafe { libc::poll(&mut fds, 1, ms) > 0 }
}
