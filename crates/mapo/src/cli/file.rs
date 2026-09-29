//! `mapo file open PATH` (PROTOCOL §9): shows a file in the workspace's file pane.

use clap::Subcommand;
use serde_json::json;

use super::Cli;
use crate::output::{CliError, print_json, wants_json};

#[derive(Subcommand)]
pub enum FileCommand {
    /// Open a file in the workspace's file pane, beside the focused terminal; prints the pane.
    Open {
        /// The file; a relative path resolves against this folder.
        path: String,
    },
}

pub fn run(cli: &Cli, cmd: &FileCommand) -> Result<(), CliError> {
    let FileCommand::Open { path } = cmd;
    let mut params = json!({ "path": absolute(path)? });
    if let Some(ws) = &cli.workspace {
        params["workspace"] = json!(ws);
    }
    let result = cli.connect()?.call("file.open", params)?;
    if wants_json(cli.json) {
        print_json(&result, cli.json);
    } else {
        println!(
            "{}  pane {}",
            result["path"].as_str().unwrap_or(""),
            result["paneId"].as_str().unwrap_or("")
        );
    }
    Ok(())
}

fn absolute(path: &str) -> Result<String, CliError> {
    let p = std::path::Path::new(path);
    if p.is_absolute() {
        return Ok(path.to_owned());
    }
    let cwd = std::env::current_dir()
        .map_err(|e| CliError::invalid(format!("can't read the current folder: {e}")))?;
    Ok(cwd.join(p).to_string_lossy().into_owned())
}
