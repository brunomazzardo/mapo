//! How the CLI prints results and errors (PROTOCOL §4).

use std::io::IsTerminal;

/// An error kind with its CLI exit code (PROTOCOL §4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    InvalidArgument,
    Conflict,
    Forbidden,
    Timeout,
    Internal,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidArgument => "invalid_argument",
            Self::Conflict => "conflict",
            Self::Forbidden => "forbidden",
            Self::Timeout => "timeout",
            Self::Internal => "internal",
        }
    }

    pub fn exit_code(self) -> i32 {
        match self {
            Self::InvalidArgument => 2,
            Self::Timeout => 124,
            _ => 1,
        }
    }
}

/// A CLI failure: a kind, a message that names the problem, and an optional next step.
#[derive(Debug)]
pub struct CliError {
    pub kind: Kind,
    pub message: String,
    pub hint: Option<String>,
}

impl CliError {
    pub fn new(kind: Kind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            hint: None,
        }
    }

    pub fn hint(mut self, hint: impl Into<String>) -> Self {
        self.hint = Some(hint.into());
        self
    }
}

impl From<mapo_instance::InstanceError> for CliError {
    fn from(err: mapo_instance::InstanceError) -> Self {
        let kind = if err.is_invalid_argument() {
            Kind::InvalidArgument
        } else if matches!(err, mapo_instance::InstanceError::MainRefused { .. }) {
            Kind::Forbidden
        } else {
            Kind::Internal
        };
        Self::new(kind, err.to_string())
    }
}

/// Whether output should be JSON: `--json`, or stdout is not a terminal.
pub fn wants_json(flag: bool) -> bool {
    flag || !std::io::stdout().is_terminal()
}

/// Prints an error the PROTOCOL §4 way and returns the exit code.
pub fn print_error(err: &CliError, json_flag: bool) -> i32 {
    if json_flag || !std::io::stderr().is_terminal() {
        let mut obj = serde_json::json!({ "error": err.message, "kind": err.kind.as_str() });
        if let Some(hint) = &err.hint {
            obj["hint"] = serde_json::Value::String(hint.clone());
        }
        eprintln!("{obj}");
    } else {
        eprintln!("mapo: {}", err.message);
        if let Some(hint) = &err.hint {
            eprintln!("{hint}");
        }
    }
    err.kind.exit_code()
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
