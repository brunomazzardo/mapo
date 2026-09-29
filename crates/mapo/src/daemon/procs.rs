//! `proc.ports` and `proc.stop` (PLAN T4.2, R-SRV-5): the current user's TCP listeners mapped to
//! tabs, and a stop that re-checks the process identity and refuses Mapo itself.

use mapo_protocol::RpcError;
use mapo_protocol::hello::CredentialKind;
use serde::Deserialize;
use serde_json::{Value, json};

use super::Shared;
use super::conn::Session;

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct PortsParams {
    #[serde(default)]
    port: Option<u16>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct StopParams {
    pid: u32,
    identity: String,
    #[serde(default)]
    force: bool,
}

/// Tab id for each live tab's terminal device and shell pid.
fn tab_terminals(shared: &Shared) -> Vec<(String, u32, Option<u32>)> {
    shared
        .host
        .all()
        .into_iter()
        .filter_map(|h| {
            let pid = h.pid()?;
            Some((h.id().to_owned(), pid, mapo_proc::tty_of(pid)))
        })
        .collect()
}

pub async fn ports(shared: &Shared, params: &Value) -> Result<Value, RpcError> {
    let p: PortsParams = mapo_protocol::parse_params(params)?;
    let uid = rustix::process::getuid().as_raw();
    let tabs = tab_terminals(shared);
    let listeners = tokio::task::spawn_blocking(move || mapo_proc::listeners(uid))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    let rows: Vec<Value> = listeners
        .into_iter()
        .filter(|l| p.port.is_none_or(|port| l.port == port))
        .map(|l| {
            let tab = tabs
                .iter()
                .find(|(_, shell, tty)| {
                    (tty.is_some() && *tty == l.tty) || mapo_proc::descends_from(l.pid, *shell)
                })
                .map(|(id, _, _)| id.clone());
            let mut v = json!(l);
            v["tabId"] = json!(tab);
            v
        })
        .collect();
    Ok(Value::Array(rows))
}

pub async fn stop(shared: &Shared, session: &Session, params: &Value) -> Result<Value, RpcError> {
    let p: StopParams = mapo_protocol::parse_params(params)?;
    if session.caller.kind == CredentialKind::Tab && !p.force {
        return Err(
            RpcError::forbidden("an agent tab must pass --force to stop a process")
                .with_hint("add --force if the user asked for it"),
        );
    }
    let me = std::process::id();
    // Never Mapo itself: the daemon, its ancestors (the app that spawned it) or the app.
    let app_pid = mapo_instance::read_pid_file(&shared.paths.app_pid_file).map(|pf| pf.pid as u32);
    let protected = p.pid == me || mapo_proc::descends_from(me, p.pid) || Some(p.pid) == app_pid;
    if protected {
        return Err(RpcError::forbidden(format!(
            "process {} is part of Mapo",
            p.pid
        )));
    }
    let current = mapo_proc::identity(p.pid).ok_or_else(|| {
        RpcError::not_found(format!("no process {}", p.pid)).with_hint("mapo ports")
    })?;
    if current != p.identity {
        return Err(RpcError::conflict(format!(
            "process {} is no longer the one listed (its identity changed)",
            p.pid
        ))
        .with_hint("mapo ports"));
    }
    let owner_ok = rustix::process::Pid::from_raw(p.pid as i32)
        .is_some_and(|pid| rustix::process::test_kill_process(pid).is_ok());
    if !owner_ok {
        return Err(RpcError::forbidden(format!(
            "process {} belongs to another user",
            p.pid
        )));
    }
    if let Some(pid) = rustix::process::Pid::from_raw(p.pid as i32) {
        rustix::process::kill_process(pid, rustix::process::Signal::TERM)
            .map_err(|e| RpcError::internal(format!("signal {}: {e}", p.pid)))?;
    }
    Ok(json!({ "signalSent": "SIGTERM", "pid": p.pid }))
}
