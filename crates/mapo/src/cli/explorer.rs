//! `mapo explorer refresh|collapse` (PROTOCOL §9): the app's Files inspector, through the daemon.

use clap::Subcommand;
use serde_json::json;

use super::Cli;
use crate::output::{CliError, print_json};

#[derive(Subcommand)]
pub enum ExplorerCommand {
    /// Reload the Files tree from disk and git; prints its root and state.
    Refresh,
    /// Collapse every folder in the Files tree.
    Collapse,
}

pub fn run(cli: &Cli, cmd: &ExplorerCommand) -> Result<(), CliError> {
    let method = match cmd {
        ExplorerCommand::Refresh => "explorer.refresh",
        ExplorerCommand::Collapse => "explorer.collapse",
    };
    let result = cli.connect()?.call(method, json!({}))?;
    print_json(&result, cli.json);
    Ok(())
}
