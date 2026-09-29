//! `mapo instance show|list|wait|stop|clean`: client-side, no daemon needed (PROTOCOL §9).

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use clap::{Args, Subcommand};
use mapo_instance::{Instance, Paths, process_alive, process_matches, read_pid_file};
use serde_json::{Value, json};

use super::Cli;
use mapo_protocol::ErrorKind as Kind;
use mapo_protocol::hello::Role;

use crate::client::Client;
use crate::output::{CliError, from_instance, print_json};

#[derive(Args)]
pub struct InstanceArgs {
    #[command(subcommand)]
    pub command: Option<InstanceCommand>,
}

#[derive(Subcommand)]
pub enum InstanceCommand {
    /// Print the resolved instance, its paths, and whether its daemon and app run.
    Show,
    /// List every instance under the data root or the runtime dir.
    List,
    /// Wait until the instance's daemon answers.
    Wait,
    /// Stop the instance's daemon.
    Stop,
    /// Delete a stopped instance's data and runtime files.
    Clean,
}

pub fn run(cli: &Cli, cmd: Option<&InstanceCommand>) -> Result<(), CliError> {
    let instance = cli.resolve_instance()?;
    match cmd.unwrap_or(&InstanceCommand::Show) {
        InstanceCommand::Show => {
            print_json(&show(&instance)?, cli.json);
            Ok(())
        }
        InstanceCommand::List => {
            print_json(&list()?, cli.json);
            Ok(())
        }
        InstanceCommand::Wait => wait(
            &instance,
            Duration::from_millis(cli.timeout_ms.unwrap_or(10_000)),
        ),
        InstanceCommand::Stop => stop(&instance),
        InstanceCommand::Clean => clean(&instance),
    }
}

/// A live process named by a pid file, if the pid still runs that executable.
fn live(pid_file: &Path, needles: &[&str]) -> Option<(i32, PathBuf)> {
    let pf = read_pid_file(pid_file)?;
    process_matches(pf.pid, &pf.exe, needles).then_some((pf.pid, pf.exe))
}

fn daemon_live(instance: &Instance, paths: &Paths) -> Option<(i32, PathBuf)> {
    live(&paths.pid_file, &["daemon", instance.name.as_str()])
}

fn show(instance: &Instance) -> Result<Value, CliError> {
    let paths = instance.paths().map_err(from_instance)?;
    mapo_instance::ensure_private_dir(&paths.runtime_dir).map_err(from_instance)?;
    let daemon = daemon_live(instance, &paths);
    let app = live(&paths.app_pid_file, &[]);
    let hello = daemon
        .as_ref()
        .and_then(|_| Client::connect(instance, Role::Cli, Some(Duration::from_secs(2))).ok())
        .map(|c| c.hello);
    let mut out = json!({
        "name": instance.name,
        "source": instance.source,
        "worktree": instance.worktree,
    });
    if let (Value::Object(out), Value::Object(p)) =
        (&mut out, serde_json::to_value(&paths).unwrap_or_default())
    {
        out.extend(p);
    }
    out["daemon"] = json!({
        "running": daemon.is_some(),
        "pid": daemon.as_ref().map(|d| d.0),
        "exe": daemon.as_ref().map(|d| d.1.clone()),
        "bootId": hello.as_ref().map(|h| h.boot_id.clone()),
        "protocol": hello.as_ref().map(|h| h.protocol),
    });
    out["app"] = json!({ "running": app.is_some(), "pid": app.as_ref().map(|a| a.0) });
    Ok(out)
}

fn dir_size(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    entries
        .flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_size(&e.path()),
            Ok(_) => e.metadata().map(|m| m.len()).unwrap_or(0),
            Err(_) => 0,
        })
        .sum()
}

fn list() -> Result<Value, CliError> {
    let data_root = mapo_instance::data_root().map_err(from_instance)?;
    let runtime = mapo_instance::runtime_dir().map_err(from_instance)?;
    let mut names = std::collections::BTreeSet::new();
    for entry in std::fs::read_dir(&data_root)
        .into_iter()
        .flatten()
        .flatten()
    {
        if entry.file_type().is_ok_and(|t| t.is_dir()) {
            names.insert(entry.file_name().to_string_lossy().into_owned());
        }
    }
    for entry in std::fs::read_dir(&runtime).into_iter().flatten().flatten() {
        let file = entry.file_name().to_string_lossy().into_owned();
        if let Some(name) = file
            .strip_suffix(".sock")
            .or_else(|| file.strip_suffix(".pid"))
        {
            names.insert(name.trim_end_matches(".app").to_owned());
        }
    }
    let rows: Vec<Value> = names
        .into_iter()
        .filter(|n| mapo_instance::is_valid_name(n))
        .map(|name| {
            let paths = Paths::with_roots(&name, &data_root, &runtime);
            let instance = Instance {
                name: name.clone(),
                source: mapo_instance::Source::Flag,
                worktree: None,
            };
            json!({
                "name": name,
                "daemon": { "running": daemon_live(&instance, &paths).is_some() },
                "app": { "running": live(&paths.app_pid_file, &[]).is_some() },
                "diskBytes": dir_size(&paths.data_dir),
                "dataDir": paths.data_dir,
            })
        })
        .collect();
    Ok(Value::Array(rows))
}

fn wait(instance: &Instance, timeout: Duration) -> Result<(), CliError> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(mut client) = Client::connect(instance, Role::Cli, Some(Duration::from_secs(2)))
            && client.call("ping", serde_json::json!({})).is_ok()
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(CliError::new(
                Kind::Timeout,
                format!(
                    "instance {} has no daemon answering after {} ms",
                    instance.name,
                    timeout.as_millis()
                ),
            )
            .with_hint(format!("mapo --instance {} daemon", instance.name)));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn signal(pid: i32, sig: rustix::process::Signal) {
    if let Some(p) = rustix::process::Pid::from_raw(pid) {
        let _ = rustix::process::kill_process(p, sig);
    }
}

/// Waits until `pid` is gone, polling every 50 ms.
fn wait_exit(pid: i32, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if !process_alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    !process_alive(pid)
}

fn stop(instance: &Instance) -> Result<(), CliError> {
    instance
        .refuse_main_from_worktree()
        .map_err(from_instance)?;
    let paths = instance.paths().map_err(from_instance)?;
    let Some((pid, exe)) = daemon_live(instance, &paths) else {
        return Ok(());
    };
    if let Ok(mut client) = Client::connect(instance, Role::Cli, Some(Duration::from_secs(2))) {
        let _ = client.call("daemon.shutdown", serde_json::json!({}));
        if wait_exit(pid, Duration::from_secs(5)) {
            return Ok(());
        }
    }
    for (sig, grace) in [
        (rustix::process::Signal::TERM, Duration::from_secs(3)),
        (rustix::process::Signal::KILL, Duration::from_secs(3)),
    ] {
        if !process_matches(pid, &exe, &["daemon", instance.name.as_str()]) {
            return Ok(());
        }
        signal(pid, sig);
        if wait_exit(pid, grace) {
            return Ok(());
        }
    }
    Err(CliError::new(
        Kind::Internal,
        format!(
            "daemon pid {pid} for instance {} did not exit",
            instance.name
        ),
    ))
}

fn clean(instance: &Instance) -> Result<(), CliError> {
    instance
        .refuse_main_from_worktree()
        .map_err(from_instance)?;
    let paths = instance.paths().map_err(from_instance)?;
    if let Some((pid, _)) = daemon_live(instance, &paths) {
        return Err(CliError::new(
            Kind::Conflict,
            format!("instance {} is running (daemon pid {pid})", instance.name),
        )
        .with_hint(format!("mapo --instance {} instance stop", instance.name)));
    }
    if let Some((pid, _)) = live(&paths.app_pid_file, &[]) {
        return Err(CliError::new(
            Kind::Conflict,
            format!("instance {} has an app running (pid {pid})", instance.name),
        ));
    }
    for file in [
        &paths.socket,
        &paths.lock,
        &paths.pid_file,
        &paths.app_pid_file,
    ] {
        let _ = std::fs::remove_file(file);
    }
    match std::fs::remove_dir_all(&paths.data_dir) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(CliError::new(
            Kind::Internal,
            format!("remove {}: {e}", paths.data_dir.display()),
        )),
    }
}
