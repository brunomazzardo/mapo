//! The clap command tree. Each group lives in its own module.

mod attach;
mod debug;
mod explorer;
mod instance;
mod pane;
mod state;
mod ui;

use clap::{Parser, Subcommand};
use mapo_protocol::hello::Role;

use crate::client::Client;
use crate::output::{CliError, from_instance, print_json};

/// Mapo: parallel terminal and Claude Code work, driven through one daemon.
#[derive(Parser)]
#[command(name = "mapo", version, about, propagate_version = true)]
pub struct Cli {
    /// The instance to talk to (default: MAPO_INSTANCE, then the worktree default, then main).
    #[arg(long, global = true)]
    pub instance: Option<String>,

    /// Print compact JSON (the default when stdout is not a terminal).
    #[arg(long, global = true)]
    pub json: bool,

    /// The workspace, by name or id (default: the caller's, then the active one).
    #[arg(long, global = true)]
    pub workspace: Option<String>,

    /// How long to wait for the daemon or a condition, in milliseconds.
    #[arg(long = "timeout-ms", global = true)]
    pub timeout_ms: Option<u64>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    /// List, create, rename, activate or delete workspaces.
    #[command(subcommand)]
    Workspace(state::WorkspaceCommand),
    /// List, create, close, rename or focus tabs.
    #[command(subcommand)]
    Tab(state::TabCommand),
    /// Split, focus, close or equalize panes.
    #[command(subcommand)]
    Pane(pane::PaneCommand),
    /// Show tab states.
    Status { name: Option<String> },
    /// Print events; with --follow, stream them.
    Events {
        #[arg(long)]
        follow: bool,
        #[arg(long)]
        after: Option<u64>,
        #[arg(long = "type")]
        types: Vec<String>,
    },
    /// Refresh or collapse the app's Files inspector.
    #[command(subcommand)]
    Explorer(explorer::ExplorerCommand),
    /// Drive the app like a person: tree, snapshot, click, type, keys, waits, metrics.
    #[command(subcommand)]
    Ui(ui::UiCommand),
    /// Show, list, wait for, stop or clean instances.
    Instance(instance::InstanceArgs),
    /// Attach this terminal to a tab (what every terminal surface runs).
    Attach(attach::AttachArgs),
    /// Run the daemon for this instance (detached unless --foreground).
    Daemon {
        /// Stay in the foreground and log to stderr too.
        #[arg(long)]
        foreground: bool,
    },
    /// Client-side diagnostics.
    #[command(subcommand)]
    Debug(debug::DebugCommand),
    /// Call any method and print the raw JSON result (for drives and debugging).
    #[command(hide = true)]
    Rpc {
        method: String,
        /// Params as a JSON object.
        params: Option<String>,
    },
}

impl Cli {
    pub fn run(&self) -> Result<(), CliError> {
        match &self.command {
            Command::Workspace(cmd) => state::workspace(self, cmd),
            Command::Tab(cmd) => state::tab(self, cmd),
            Command::Pane(cmd) => pane::run(self, cmd),
            Command::Status { name } => state::status(self, name.as_deref()),
            Command::Events {
                follow,
                after,
                types,
            } => state::events(self, *follow, *after, types),
            Command::Ui(cmd) => ui::run(self, cmd),
            Command::Explorer(cmd) => explorer::run(self, cmd),
            Command::Instance(args) => instance::run(self, args.command.as_ref()),
            Command::Attach(args) => attach::run(self, args),
            Command::Daemon { foreground } => {
                crate::daemon::run(&self.resolve_instance()?, *foreground)
            }
            Command::Debug(cmd) => debug::run(self, cmd),
            Command::Rpc { method, params } => {
                let params = match params {
                    Some(p) => serde_json::from_str(p).map_err(|e| {
                        CliError::invalid(format!("params must be a JSON object: {e}"))
                    })?,
                    None => serde_json::json!({}),
                };
                let result = self.connect()?.call(method, params)?;
                print_json(&result, self.json);
                Ok(())
            }
        }
    }

    /// Resolves the instance for this invocation (ENGINEERING §2.1).
    pub fn resolve_instance(&self) -> Result<mapo_instance::Instance, CliError> {
        mapo_instance::resolve_current(self.instance.as_deref()).map_err(from_instance)
    }

    /// Connects to this instance's daemon as a CLI client.
    pub fn connect(&self) -> Result<Client, CliError> {
        let timeout = self
            .timeout_ms
            .map(|ms| std::time::Duration::from_millis(ms + 1000));
        Client::connect(&self.resolve_instance()?, Role::Cli, timeout)
    }
}
