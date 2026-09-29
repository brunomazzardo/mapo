//! `mapo`: the daemon, attach client, hooks, MCP server and CLI in one binary (DECISIONS D-26).

mod cli;
mod output;

use clap::Parser;

use crate::cli::Cli;

fn main() {
    let cli = Cli::parse();
    let code = match cli.run() {
        Ok(()) => 0,
        Err(err) => output::print_error(&err, cli.json),
    };
    std::process::exit(code);
}
