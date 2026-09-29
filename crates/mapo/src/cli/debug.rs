//! `mapo debug stats`: CPU time and physical footprint of this instance's daemon and app,
//! read with proc_pid_rusage from the pid files (ENGINEERING §6).

use std::time::Duration;

use clap::Subcommand;
use serde_json::{Value, json};

use super::Cli;
use crate::output::{CliError, from_instance, print_json};

#[derive(Subcommand)]
pub enum DebugCommand {
    /// Footprint and CPU of the daemon and the app; with --interval-ms, CPU % over that interval.
    Stats {
        #[arg(long = "interval-ms")]
        interval_ms: Option<u64>,
    },
}

#[derive(Clone, Copy)]
struct Usage {
    cpu_ns: u64,
    footprint: u64,
}

// libc marks the mach timebase deprecated in favor of the mach2 crate; one call is not worth a dependency.
#[allow(unsafe_code, deprecated)]
fn usage(pid: i32) -> Option<Usage> {
    let mut info = std::mem::MaybeUninit::<libc::rusage_info_v2>::zeroed();
    // SAFETY: proc_pid_rusage fills one rusage_info_v2 for flavor RUSAGE_INFO_V2 into memory we own.
    let rc = unsafe { libc::proc_pid_rusage(pid, libc::RUSAGE_INFO_V2, info.as_mut_ptr().cast()) };
    if rc != 0 {
        return None;
    }
    // SAFETY: rc == 0 means the struct was written.
    let info = unsafe { info.assume_init() };
    let mut tb = libc::mach_timebase_info { numer: 0, denom: 0 };
    // SAFETY: mach_timebase_info writes the timebase into a struct we own.
    unsafe { libc::mach_timebase_info(&mut tb) };
    let ticks = info.ri_user_time + info.ri_system_time;
    let cpu_ns = if tb.denom == 0 {
        ticks
    } else {
        ticks.saturating_mul(u64::from(tb.numer)) / u64::from(tb.denom)
    };
    Some(Usage {
        cpu_ns,
        footprint: info.ri_phys_footprint,
    })
}

fn pid_of(path: &std::path::Path) -> Option<i32> {
    let pf = mapo_instance::read_pid_file(path)?;
    mapo_instance::process_matches(pf.pid, &pf.exe, &[]).then_some(pf.pid)
}

pub fn run(cli: &Cli, cmd: &DebugCommand) -> Result<(), CliError> {
    let DebugCommand::Stats { interval_ms } = cmd;
    let instance = cli.resolve_instance()?;
    let paths = instance.paths().map_err(from_instance)?;
    let procs = [
        ("daemon", pid_of(&paths.pid_file)),
        ("app", pid_of(&paths.app_pid_file)),
    ];
    let before: Vec<Option<Usage>> = procs.iter().map(|(_, p)| p.and_then(usage)).collect();
    if let Some(ms) = interval_ms {
        std::thread::sleep(Duration::from_millis(*ms));
    }
    let mut out = json!({ "instance": instance.name });
    for (i, (name, pid)) in procs.iter().enumerate() {
        let now = pid.and_then(usage);
        let cpu_percent = match (interval_ms, before[i], now) {
            (Some(ms), Some(a), Some(b)) if *ms > 0 => {
                Value::from((b.cpu_ns.saturating_sub(a.cpu_ns)) as f64 / (*ms as f64 * 1e6) * 100.0)
            }
            _ => Value::Null,
        };
        out[*name] = json!({
            "running": now.is_some(),
            "pid": pid,
            "footprintBytes": now.map(|u| u.footprint),
            "cpuTimeMs": now.map(|u| u.cpu_ns / 1_000_000),
            "cpuPercent": cpu_percent,
        });
    }
    if let Ok(mut client) = cli.connect()
        && let Ok(snapshot) = client.call("state.snapshot", json!({}))
    {
        out["counts"] = json!({
            "workspaces": snapshot["workspaces"].as_array().map(Vec::len),
            "tabs": snapshot["tabs"].as_array().map(Vec::len),
        });
    }
    print_json(&out, cli.json);
    Ok(())
}
