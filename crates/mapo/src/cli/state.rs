//! Workspace, tab, status and events verbs (PROTOCOL §9).

use std::io::Write as _;

use clap::Subcommand;
use mapo_protocol::rpc::Incoming;
use serde_json::{Value, json};

use super::Cli;
use crate::output::{CliError, wants_json};

#[derive(Subcommand)]
pub enum WorkspaceCommand {
    /// List workspaces.
    List,
    /// Create a workspace (default name: the first free "Workspace N").
    New { name: Option<String> },
    /// Rename a workspace.
    Rename { name: String, new_name: String },
    /// Make a workspace the active one.
    Activate { name: String },
    /// Delete a workspace and close its tabs.
    Delete {
        name: String,
        #[arg(long)]
        force: bool,
    },
}

#[derive(Subcommand)]
pub enum TabCommand {
    /// List the tabs of a workspace.
    List,
    /// Create a tab.
    New {
        #[arg(long)]
        name: Option<String>,
        /// shell or agent (aliases: terminal, claude).
        #[arg(long)]
        kind: Option<String>,
        #[arg(long)]
        cwd: Option<String>,
        /// A command to run in the interactive shell after the first prompt.
        #[arg(long)]
        cmd: Option<String>,
        #[arg(long)]
        focus: bool,
    },
    /// Close a tab.
    Close {
        name: String,
        #[arg(long)]
        force: bool,
    },
    /// Rename a tab.
    Rename { name: String, new_name: String },
    /// Show a tab and activate its workspace.
    Focus { name: String },
}

fn with_ws(cli: &Cli, mut params: Value) -> Value {
    if let Some(ws) = &cli.workspace {
        params["workspace"] = json!(ws);
    }
    params
}

fn call(cli: &Cli, method: &str, params: Value) -> Result<Value, CliError> {
    cli.connect()?.call(method, params)
}

/// Prints JSON when piped or with --json, else a small table of `cols`.
fn print(cli: &Cli, value: &Value, cols: &[&str]) {
    if wants_json(cli.json) {
        println!("{value}");
        return;
    }
    let rows: Vec<&Value> = match value {
        Value::Array(items) => items.iter().collect(),
        other => vec![other],
    };
    let text = |v: &Value| match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    };
    let widths: Vec<usize> = cols
        .iter()
        .map(|c| {
            rows.iter()
                .map(|r| text(&r[*c]).chars().count())
                .max()
                .unwrap_or(0)
                .max(c.len())
        })
        .collect();
    let line = |cells: Vec<String>| {
        cells
            .iter()
            .zip(&widths)
            .map(|(c, w)| format!("{c:<w$}"))
            .collect::<Vec<_>>()
            .join("  ")
            .trim_end()
            .to_owned()
    };
    println!("{}", line(cols.iter().map(|c| c.to_uppercase()).collect()));
    for r in rows {
        println!("{}", line(cols.iter().map(|c| text(&r[*c])).collect()));
    }
}

const WS_COLS: &[&str] = &["name", "tabCount", "state", "stateLabel"];
const TAB_COLS: &[&str] = &["name", "kind", "state", "cwd", "title"];

pub fn workspace(cli: &Cli, cmd: &WorkspaceCommand) -> Result<(), CliError> {
    let (method, params) = match cmd {
        WorkspaceCommand::List => ("workspace.list", json!({})),
        WorkspaceCommand::New { name } => ("workspace.create", json!({ "name": name })),
        WorkspaceCommand::Rename { name, new_name } => (
            "workspace.rename",
            json!({ "workspace": name, "name": new_name }),
        ),
        WorkspaceCommand::Activate { name } => ("workspace.activate", json!({ "workspace": name })),
        WorkspaceCommand::Delete { name, force } => (
            "workspace.delete",
            json!({ "workspace": name, "force": force }),
        ),
    };
    let params = strip_nulls(params);
    let result = call(cli, method, params)?;
    print(cli, &result, WS_COLS);
    Ok(())
}

pub fn tab(cli: &Cli, cmd: &TabCommand) -> Result<(), CliError> {
    let (method, params) = match cmd {
        TabCommand::List => ("tab.list", json!({})),
        TabCommand::New {
            name,
            kind,
            cwd,
            cmd,
            focus,
        } => {
            let cwd = match cwd {
                Some(c) => Some(absolute(c)?),
                None => None,
            };
            (
                "tab.create",
                json!({ "name": name, "kind": kind, "cwd": cwd, "command": cmd, "focus": focus.then_some(true) }),
            )
        }
        TabCommand::Close { name, force } => ("tab.close", json!({ "tab": name, "force": force })),
        TabCommand::Rename { name, new_name } => {
            ("tab.rename", json!({ "tab": name, "name": new_name }))
        }
        TabCommand::Focus { name } => ("tab.focus", json!({ "tab": name })),
    };
    let result = call(cli, method, with_ws(cli, strip_nulls(params)))?;
    print(cli, &result, TAB_COLS);
    Ok(())
}

/// `mapo status [NAME]`: tabs of a workspace, or one tab.
pub fn status(cli: &Cli, name: Option<&str>) -> Result<(), CliError> {
    let tabs = call(cli, "tab.list", with_ws(cli, json!({})))?;
    let result = match name {
        None => tabs,
        Some(n) => tabs
            .as_array()
            .and_then(|a| a.iter().find(|t| t["name"] == n || t["id"] == n).cloned())
            .ok_or_else(|| {
                CliError::not_found(format!("Tab \"{n}\" not found")).with_hint("mapo tab list")
            })?,
    };
    print(
        cli,
        &result,
        &["name", "state", "stateLabel", "program", "cwd"],
    );
    Ok(())
}

/// `mapo events [--follow] [--after SEQ] [--type T]`.
pub fn events(
    cli: &Cli,
    follow: bool,
    after: Option<u64>,
    types: &[String],
) -> Result<(), CliError> {
    let mut client = cli.connect()?;
    let mut params = json!({ "after": after.unwrap_or(0) });
    if !types.is_empty() {
        params["types"] = json!(types);
    }
    let id = client.send("events.subscribe", params)?;
    let mut last_seq = None;
    let stdout = std::io::stdout();
    loop {
        match client.read()? {
            Incoming::Response(resp) if resp.id.as_ref() == Some(&id) => {
                let result = resp.into_result()?;
                last_seq = result["seq"].as_u64();
                if !follow && last_seq.is_some_and(|s| s <= after.unwrap_or(0)) {
                    return Ok(());
                }
            }
            Incoming::Response(resp) => {
                resp.into_result()?;
            }
            Incoming::Notification(n) if n.method == "event" => {
                let mut out = stdout.lock();
                let _ = writeln!(out, "{}", n.params);
                let _ = out.flush();
                if !follow && n.params["seq"].as_u64() >= last_seq {
                    return Ok(());
                }
            }
            _ => {}
        }
    }
}

fn strip_nulls(mut v: Value) -> Value {
    if let Value::Object(map) = &mut v {
        map.retain(|_, x| !x.is_null() && *x != Value::Bool(false));
    }
    v
}

fn absolute(path: &str) -> Result<String, CliError> {
    let p = std::path::Path::new(path);
    if p.is_absolute() {
        return Ok(path.to_owned());
    }
    let cwd =
        std::env::current_dir().map_err(|e| CliError::internal(format!("current dir: {e}")))?;
    Ok(cwd.join(p).display().to_string())
}
