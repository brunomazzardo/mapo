//! `mapo`: the daemon, attach client, hooks, MCP server and CLI in one binary (DECISIONS D-26).

mod cli;
mod client;
mod daemon;
mod output;

use std::ffi::OsString;
use std::io::IsTerminal;

use clap::error::ErrorKind as ClapKind;
use clap::{CommandFactory, Parser};

use crate::cli::Cli;

fn main() {
    let args = tab_id_alias(std::env::args_os().collect());
    let json_flag = args.iter().any(|a| a == "--json");
    let cli = match Cli::try_parse_from(&args) {
        Ok(cli) => cli,
        Err(err) => usage_error(err, &args, json_flag),
    };
    let code = match cli.run() {
        Ok(()) => 0,
        Err(err) => output::print_error(&err, cli.json),
    };
    std::process::exit(code);
}

/// Global options that take a value, so their values are never read as a noun or verb.
const VALUE_OPTIONS: &[&str] = &["--instance", "--workspace", "--timeout-ms"];

/// The VS Code build's `--tab-id ID` (R-CTL-2): `tab` accepts an ID, so `mapo tab VERB --tab-id ID
/// REST…` becomes `mapo tab VERB ID REST…`. Anything else is left for clap to judge.
fn tab_id_alias(mut args: Vec<OsString>) -> Vec<OsString> {
    let Some(at) = args
        .iter()
        .position(|a| a == "--tab-id" || a.to_string_lossy().starts_with("--tab-id="))
    else {
        return args;
    };
    let flag = args.remove(at).to_string_lossy().into_owned();
    let id = match flag.strip_prefix("--tab-id=") {
        Some(id) => OsString::from(id),
        None if at < args.len() => args.remove(at),
        None => return args,
    };
    // The first two positionals after the program must be `tab VERB`.
    let mut positionals = Vec::new();
    let mut i = 1;
    while i < args.len() && positionals.len() < 2 {
        let arg = args[i].to_string_lossy();
        if VALUE_OPTIONS.contains(&arg.as_ref()) {
            i += 2;
            continue;
        }
        if !arg.starts_with('-') {
            positionals.push(i);
        }
        i += 1;
    }
    match positionals.as_slice() {
        [noun, verb] if args[*noun] == "tab" => args.insert(verb + 1, id),
        // Not `tab VERB`: put the flag back so clap reports it.
        _ => {
            args.insert(at, id);
            args.insert(at, OsString::from("--tab-id"));
        }
    }
    args
}

/// Help and version print as clap prints them. A usage error exits 2; piped or with `--json` it is
/// one PROTOCOL §4 line on stderr, `{"error", "kind": "invalid_argument", "hint"}`.
fn usage_error(err: clap::Error, args: &[OsString], json_flag: bool) -> ! {
    if matches!(err.kind(), ClapKind::DisplayHelp | ClapKind::DisplayVersion)
        || (!json_flag && std::io::stderr().is_terminal())
    {
        err.exit();
    }
    let text = err.render().to_string();
    let message = if err.kind() == ClapKind::DisplayHelpOnMissingArgumentOrSubcommand {
        "a command is required".to_owned()
    } else {
        // The first paragraph: "error: …", plus the missing arguments clap lists under it.
        let lines: Vec<&str> = text
            .lines()
            .take_while(|l| !l.trim().is_empty())
            .map(str::trim)
            .collect();
        lines.join(" ").trim_start_matches("error: ").to_owned()
    };
    let rpc = output::CliError::invalid(message).with_hint(usage_hint(args));
    std::process::exit(output::print_error(&rpc, true));
}

/// `mapo NOUN VERB --help` for the deepest subcommand the arguments name.
fn usage_hint(args: &[OsString]) -> String {
    let mut cmd = Cli::command();
    let mut words = vec!["mapo".to_owned()];
    let mut i = 1;
    while i < args.len() {
        let arg = args[i].to_string_lossy();
        if VALUE_OPTIONS.contains(&arg.as_ref()) {
            i += 2;
            continue;
        }
        i += 1;
        if arg.starts_with('-') {
            continue;
        }
        let Some(sub) = cmd.find_subcommand(arg.as_ref()).cloned() else {
            break;
        };
        words.push(sub.get_name().to_owned());
        cmd = sub;
    }
    format!("{} --help", words.join(" "))
}
