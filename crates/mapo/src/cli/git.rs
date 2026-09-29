//! `mapo git changes [PATH]` (PROTOCOL §9): the files changed against HEAD, as the Changes inspector
//! shows them.

use clap::Subcommand;
use serde_json::{Value, json};

use super::Cli;
use crate::output::{CliError, print_json, wants_json};

#[derive(Subcommand)]
pub enum GitCommand {
    /// List the files changed against HEAD in PATH's repository (default: this folder), with +/- counts.
    Changes {
        /// A folder or file inside the repository.
        path: Option<String>,
    },
}

pub fn run(cli: &Cli, cmd: &GitCommand) -> Result<(), CliError> {
    let GitCommand::Changes { path } = cmd;
    let cwd = std::env::current_dir()
        .map_err(|e| CliError::invalid(format!("can't read the current folder: {e}")))?;
    let path = match path {
        Some(p) => cwd.join(p),
        None => cwd,
    };
    let result = cli
        .connect()?
        .call("git.status", json!({ "path": path.to_string_lossy() }))?;
    if wants_json(cli.json) {
        print_json(&result, cli.json);
    } else {
        print_human(&result);
    }
    Ok(())
}

fn print_human(r: &Value) {
    let branch = match (r["branch"].as_str(), r["head"].as_str()) {
        (Some(b), _) => b.to_owned(),
        (None, Some(head)) => format!("detached at {head}"),
        (None, None) => "no commit yet".to_owned(),
    };
    let mut upstream = String::new();
    let (ahead, behind) = (
        r["ahead"].as_u64().unwrap_or(0),
        r["behind"].as_u64().unwrap_or(0),
    );
    if ahead > 0 {
        upstream.push_str(&format!(" ↑{ahead}"));
    }
    if behind > 0 {
        upstream.push_str(&format!(" ↓{behind}"));
    }
    let t = &r["totals"];
    println!(
        "{branch}{upstream}  {} files  +{} −{}",
        t["files"].as_u64().unwrap_or(0),
        t["added"].as_u64().unwrap_or(0),
        t["deleted"].as_u64().unwrap_or(0)
    );
    if let Some(warn) = r["warn"].as_str() {
        println!("{warn}");
    }
    for f in r["files"].as_array().into_iter().flatten() {
        let letter = match f["status"].as_str().unwrap_or("") {
            "?" => "U",
            "U" => "C",
            other => other,
        };
        let counts = if f["binary"].as_bool() == Some(true) {
            "bin".to_owned()
        } else {
            format!(
                "+{} −{}",
                f["added"].as_u64().unwrap_or(0),
                f["deleted"].as_u64().unwrap_or(0)
            )
        };
        println!("{letter}  {}  {counts}", f["path"].as_str().unwrap_or(""));
    }
}
