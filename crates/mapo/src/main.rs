use clap::Parser;

/// Mapo: the daemon, attach client and CLI in one binary.
#[derive(Parser)]
#[command(name = "mapo", version, about)]
struct Cli {}

fn main() -> anyhow::Result<()> {
    let _cli = Cli::parse();
    Ok(())
}
