//! How the CLI prints results and errors (PROTOCOL §4).

use std::io::IsTerminal;

use mapo_protocol::{ErrorKind, RpcError};

/// A CLI failure is a protocol error: kind, message and hint.
pub type CliError = RpcError;

pub fn from_instance(err: mapo_instance::InstanceError) -> CliError {
    let kind = if err.is_invalid_argument() {
        ErrorKind::InvalidArgument
    } else if matches!(err, mapo_instance::InstanceError::MainRefused { .. }) {
        ErrorKind::Forbidden
    } else {
        ErrorKind::Internal
    };
    RpcError::new(kind, err.to_string())
}

/// Whether output should be JSON: `--json`, or stdout is not a terminal.
pub fn wants_json(flag: bool) -> bool {
    flag || !std::io::stdout().is_terminal()
}

/// Prints an error the PROTOCOL §4 way and returns the exit code.
pub fn print_error(err: &CliError, json_flag: bool) -> i32 {
    if json_flag || !std::io::stderr().is_terminal() {
        eprintln!("{}", err.cli_line());
    } else {
        eprintln!("mapo: {}", err.message);
        if let Some(hint) = &err.data.hint {
            eprintln!("{hint}");
        }
    }
    err.kind().exit_code()
}

/// Prints a JSON value compactly when piped or with `--json`, else pretty.
pub fn print_json(value: &serde_json::Value, json_flag: bool) {
    if wants_json(json_flag) {
        println!("{value}");
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(value).unwrap_or_default()
        );
    }
}
