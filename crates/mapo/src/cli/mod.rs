//! The clap command tree. Each group lives in its own module.

mod instance;

use clap::{Parser, Subcommand};

use crate::output::CliError;

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
}

impl Cli {
    pub fn run(&self) -> Result<(), CliError> {
        match &self.command {
            Command::Instance(args) => instance::run(self, args.command.as_ref()),
        }
    }

    /// Resolves the instance for this invocation (ENGINEERING §2.1).
    pub fn resolve_instance(&self) -> Result<mapo_instance::Instance, CliError> {
        Ok(mapo_instance::resolve_current(self.instance.as_deref())?)
    }
}
