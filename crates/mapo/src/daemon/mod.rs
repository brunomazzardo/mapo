//! `mapo daemon`: one daemon per instance that owns state and processes (ARCHITECTURE §3,
//! ENGINEERING §2.3). Without `--foreground` it detaches and waits until the daemon answers.

mod conn;
mod host;
mod logging;

use std::os::fd::AsFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use mapo_instance::{Instance, Paths, Secret};
use mapo_protocol::RpcError;
use mapo_protocol::hello::Role;
use serde_json::json;
use tokio::net::UnixListener;
use tokio::sync::watch;

use crate::client::Client;

/// Immutable daemon facts shared by every connection.
pub struct Shared {
    pub instance: String,
    pub paths: Paths,
    pub boot_id: String,
    pub started: Instant,
    pub token: Secret,
    pub shutdown: watch::Sender<bool>,
    /// Asks the accept loop to stop (daemon.shutdown); it then flips `shutdown` for everyone.
    pub stop_request: tokio::sync::Notify,
    pub core: mapo_core::CoreHandle,
    pub host: Arc<host::Host>,
}

/// `mapo daemon [--foreground]`.
pub fn run(instance: &Instance, foreground: bool) -> Result<(), RpcError> {
    instance
        .refuse_main_from_worktree()
        .map_err(|e| RpcError::forbidden(e.to_string()))?;
    if foreground {
        serve(instance)
    } else {
        detach(instance)
    }
}

fn ping(instance: &Instance) -> Option<i64> {
    let mut client = Client::connect(instance, Role::Cli, Some(Duration::from_secs(2))).ok()?;
    client.call("ping", json!({})).ok()?;
    let info = client.call("instance.info", json!({})).ok()?;
    info.get("daemonPid").and_then(|p| p.as_i64())
}

fn print_running(pid: i64, paths: &Paths) {
    println!("{}", json!({ "pid": pid, "socket": paths.socket }));
}

/// Spawns `current_exe daemon --foreground` in its own session and waits up to 10 s for ping.
fn detach(instance: &Instance) -> Result<(), RpcError> {
    let paths = instance
        .paths()
        .map_err(|e| RpcError::internal(e.to_string()))?;
    if let Some(pid) = ping(instance) {
        print_running(pid, &paths);
        return Ok(());
    }
    let exe =
        std::env::current_exe().map_err(|e| RpcError::internal(format!("current_exe: {e}")))?;
    let mut cmd = std::process::Command::new(exe);
    cmd.args(["daemon", "--foreground", "--instance", &instance.name])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    new_session(&mut cmd);
    let mut child = cmd
        .spawn()
        .map_err(|e| RpcError::internal(format!("spawn daemon: {e}")))?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Ok(Some(status)) = child.try_wait() {
            let log = paths
                .log_dir
                .join(format!("mapod.{}.log", logging::today()));
            return Err(RpcError::internal(format!(
                "the daemon exited during startup ({status}); see {}",
                log.display()
            )));
        }
        if let Some(pid) = ping(instance) {
            print_running(pid, &paths);
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    Err(RpcError::new(
        mapo_protocol::ErrorKind::Timeout,
        format!("the daemon for {} didn't answer within 10 s", instance.name),
    ))
}

#[allow(unsafe_code)]
fn new_session(cmd: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;
    // SAFETY: setsid is async-signal-safe and touches no memory of the parent.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

/// Holds the instance lock for the daemon's lifetime; the kernel drops it on exit.
struct Lock(#[allow(dead_code)] std::fs::File);

fn take_lock(paths: &Paths, name: &str) -> Result<Lock, RpcError> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&paths.lock)
        .map_err(|e| RpcError::internal(format!("open {}: {e}", paths.lock.display())))?;
    match rustix::fs::flock(
        file.as_fd(),
        rustix::fs::FlockOperation::NonBlockingLockExclusive,
    ) {
        Ok(()) => Ok(Lock(file)),
        Err(_) => {
            let owner = mapo_instance::read_pid_file(&paths.pid_file)
                .map(|p| format!("pid {} ({})", p.pid, p.exe.display()))
                .unwrap_or_else(|| "another process".into());
            Err(RpcError::conflict(format!(
                "instance {name} is already served by {owner}"
            )))
        }
    }
}

fn bind(paths: &Paths) -> Result<UnixListener, RpcError> {
    let _ = std::fs::remove_file(&paths.socket);
    let old = rustix::process::umask(rustix::fs::Mode::from_raw_mode(0o177));
    let listener = UnixListener::bind(&paths.socket);
    rustix::process::umask(old);
    listener.map_err(|e| RpcError::internal(format!("bind {}: {e}", paths.socket.display())))
}

fn serve(instance: &Instance) -> Result<(), RpcError> {
    let paths = instance
        .paths()
        .map_err(|e| RpcError::internal(e.to_string()))?;
    paths
        .ensure_dirs()
        .map_err(|e| RpcError::internal(e.to_string()))?;
    let _guard = logging::init(&paths.log_dir);
    let _lock = take_lock(&paths, &instance.name)?;
    let pid = std::process::id() as i32;
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("mapo"));
    mapo_instance::write_pid_file(&paths.pid_file, pid, &exe)
        .map_err(|e| RpcError::internal(e.to_string()))?;
    let token = Secret::generate().map_err(|e| RpcError::internal(e.to_string()))?;
    mapo_instance::write_token(&paths.token, &token)
        .map_err(|e| RpcError::internal(e.to_string()))?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| RpcError::internal(format!("tokio: {e}")))?;
    let (shutdown, _) = watch::channel(false);
    let boot_id = uuid::Uuid::now_v7().to_string();
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    let result = runtime.block_on(async {
        let (host_tx, host_rx) = tokio::sync::mpsc::unbounded_channel();
        let core = mapo_core::spawn(mapo_core::actor::Options {
            state_db: &paths.state_db,
            boot_id: boot_id.clone(),
            home,
            host: host_tx,
        })
        .map_err(|e| RpcError::internal(e.to_string()))?;
        let sink_core = core.clone();
        let ctx = Arc::new(mapo_term::tab::HostContext {
            instance: instance.name.clone(),
            resources: mapo_term::env::Resources::from_exe(&exe),
            shell: mapo_term::env::login_shell(None),
            scrollback: 10_000,
            sink: Arc::new(move |id: &str, fact| sink_core.tab_fact(id, fact)),
        });
        let host = host::spawn(host_rx, ctx);
        let shared = Arc::new(Shared {
            instance: instance.name.clone(),
            paths: paths.clone(),
            boot_id,
            started: Instant::now(),
            token,
            shutdown,
            stop_request: tokio::sync::Notify::new(),
            core: core.clone(),
            host: host.clone(),
        });
        let result = accept_loop(shared).await;
        host.close_all().await;
        core.flush().await;
        result
    });
    runtime.shutdown_timeout(Duration::from_secs(1));
    let _ = std::fs::remove_file(&paths.socket);
    mapo_instance::remove_pid_file(&paths.pid_file, pid);
    tracing::info!("stopped");
    result
}

async fn accept_loop(shared: Arc<Shared>) -> Result<(), RpcError> {
    let mut listener = bind(&shared.paths)?;
    tracing::info!(instance = %shared.instance, boot_id = %shared.boot_id, pid = std::process::id(), "ready");
    let mut term = signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut int = signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut check = tokio::time::interval(Duration::from_secs(60));
    check.tick().await;
    let uid = rustix::process::geteuid().as_raw();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    match stream.peer_cred() {
                        Ok(cred) if cred.uid() == uid => {
                            tokio::spawn(conn::handle(shared.clone(), stream));
                        }
                        _ => tracing::warn!("dropped a connection from another user"),
                    }
                }
                Err(e) => tracing::warn!(error = %e, "accept failed"),
            },
            _ = check.tick() => {
                if !shared.paths.socket.exists() {
                    tracing::warn!("socket file vanished; rebinding");
                    listener = bind(&shared.paths)?;
                }
            }
            _ = term.recv() => { tracing::info!("SIGTERM"); break; }
            _ = int.recv() => { tracing::info!("SIGINT"); break; }
            _ = shared.stop_request.notified() => { tracing::info!("daemon.shutdown"); break; }
        }
    }
    drop(listener);
    shared.core.emit("daemon.stopping", json!({}));
    shared.core.flush().await;
    tokio::time::sleep(Duration::from_millis(20)).await;
    let _ = shared.shutdown.send(true);
    Ok(())
}

fn signal(kind: tokio::signal::unix::SignalKind) -> Result<tokio::signal::unix::Signal, RpcError> {
    tokio::signal::unix::signal(kind)
        .map_err(|e| RpcError::internal(format!("signal handler: {e}")))
}
