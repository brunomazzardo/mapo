//! `mapo hook`: what Claude's hooks run (ARCHITECTURE §3.5). Reads at most 1 MiB of hook JSON from
//! stdin, keeps only the fields `hook.report` accepts, and always exits 0 within 2 s: it must never
//! block or fail Claude. It prints nothing and logs only to `hook.<date>.log`.

use std::io::{Read, Write as _};
use std::time::Duration;

use mapo_protocol::hello::{Credential, CredentialKind, Role};

use super::Cli;
use crate::client::Client;

const MAX_INPUT: u64 = 1 << 20;

fn log(cli: &Cli, line: &str) {
    let Ok(instance) = cli.resolve_instance() else {
        return;
    };
    let Ok(paths) = instance.paths() else {
        return;
    };
    let file = paths
        .log_dir
        .join(format!("hook.{}.log", crate::daemon::today()));
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(file)
    {
        let _ = writeln!(f, "pid={} {line}", std::process::id());
    }
}

fn report(cli: &Cli) -> Result<String, String> {
    let token = std::env::var("MAPO_HOOK_TOKEN").map_err(|_| "no MAPO_HOOK_TOKEN".to_owned())?;
    let mut input = String::new();
    std::io::stdin()
        .take(MAX_INPUT)
        .read_to_string(&mut input)
        .map_err(|e| format!("stdin: {e}"))?;
    let report = mapo_agent::report_from_hook_json(&input).ok_or("not a hook payload")?;
    let instance = cli.resolve_instance().map_err(|e| e.message)?;
    let credential = Credential {
        kind: CredentialKind::Hook,
        token,
    };
    let mut client = Client::connect_with(
        &instance,
        Role::Hook,
        credential,
        Some(Duration::from_millis(1500)),
    )
    .map_err(|e| e.message)?;
    let params = serde_json::to_value(&report).map_err(|e| e.to_string())?;
    let result = client.call("hook.report", params).map_err(|e| e.message)?;
    Ok(format!("{} -> {}", report.event, result["state"]))
}

pub fn run(cli: &Cli) -> ! {
    // A hard deadline: whatever happens, Claude gets exit 0 within 2 s.
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_millis(1900));
        std::process::exit(0);
    });
    match report(cli) {
        Ok(line) => log(cli, &line),
        Err(e) => log(cli, &format!("dropped: {e}")),
    }
    std::process::exit(0);
}
