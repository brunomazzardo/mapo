//! The clap command tree. Each group lives in its own module.

mod debug;
mod instance;

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

    /// How long to wait for the daemon or a condition, in milliseconds.
    #[arg(long = "timeout-ms", global = true)]
    pub timeout_ms: Option<u64>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    /// Show, list, wait for, stop or clean instances.
    Instance(instance::InstanceArgs),
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
            Command::Instance(args) => instance::run(self, args.command.as_ref()),
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
