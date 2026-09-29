//! Pane verbs (PROTOCOL §6.4, §9): split, focus, close, equalize.

use clap::{Subcommand, ValueEnum};
use serde_json::{Value, json};

use super::Cli;
use crate::output::{CliError, wants_json};

#[derive(Clone, Copy, ValueEnum)]
pub enum SplitDirection {
    Right,
    Down,
}

#[derive(Clone, Copy, ValueEnum)]
pub enum FocusDirection {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Subcommand)]
pub enum PaneCommand {
    /// Split the focused pane; the new pane gets a new shell in the same folder, or --tab/--file.
    Split {
        direction: SplitDirection,
        /// Show this tab (by name) in the new pane instead of a new shell.
        #[arg(long, conflicts_with = "file")]
        tab: Option<String>,
        /// Show this file in the new pane instead of a new shell.
        #[arg(long)]
        file: Option<String>,
        /// The pane to split (default: the focused pane).
        #[arg(long)]
        pane: Option<String>,
    },
    /// Move focus to the nearest pane in a direction, or to --pane ID.
    Focus {
        #[arg(required_unless_present = "pane")]
        direction: Option<FocusDirection>,
        #[arg(long, conflicts_with = "direction")]
        pane: Option<String>,
    },
    /// Close the focused pane (or --pane ID). Its tab keeps running in the background.
    Close {
        #[arg(long)]
        pane: Option<String>,
    },
    /// Give every pane of the workspace an equal share.
    Equalize,
}

pub fn run(cli: &Cli, cmd: &PaneCommand) -> Result<(), CliError> {
    let (method, mut params) = match cmd {
        PaneCommand::Split {
            direction,
            tab,
            file,
            pane,
        } => {
            let direction = match direction {
                SplitDirection::Right => "right",
                SplitDirection::Down => "down",
            };
            let content = match (tab, file) {
                (Some(tab), _) => json!({ "tab": tab }),
                (None, Some(file)) => json!({ "file": absolute(file)? }),
                (None, None) => json!("new-shell"),
            };
            (
                "pane.split",
                json!({ "direction": direction, "content": content, "pane": pane }),
            )
        }
        PaneCommand::Focus { direction, pane } => {
            let direction = direction.map(|d| match d {
                FocusDirection::Left => "left",
                FocusDirection::Right => "right",
                FocusDirection::Up => "up",
                FocusDirection::Down => "down",
            });
            (
                "pane.focus",
                json!({ "direction": direction, "pane": pane }),
            )
        }
        PaneCommand::Close { pane } => ("pane.close", json!({ "pane": pane })),
        PaneCommand::Equalize => ("pane.equalize", json!({})),
    };
    if let Value::Object(map) = &mut params {
        map.retain(|_, v| !v.is_null());
        if let Some(ws) = &cli.workspace {
            map.insert("workspace".into(), json!(ws));
        }
    }
    let layout = cli.connect()?.call(method, params)?;
    if wants_json(cli.json) {
        println!("{layout}");
    } else {
        print_tree(
            &layout["root"],
            layout["focusedPaneId"].as_str().unwrap_or(""),
            0,
        );
    }
    Ok(())
}

/// One line per node: splits as `row 50%/50%`, panes as `* <id>  tab <id>`, the focused one starred.
fn print_tree(node: &Value, focused: &str, depth: usize) {
    let indent = "  ".repeat(depth);
    let id = node["id"].as_str().unwrap_or("");
    if node["kind"] == "split" {
        let ratios: Vec<String> = node["ratios"]
            .as_array()
            .map(|r| {
                r.iter()
                    .map(|x| format!("{:.0}%", x.as_f64().unwrap_or(0.0) * 100.0))
                    .collect()
            })
            .unwrap_or_default();
        println!(
            "{indent}{} {}",
            node["axis"].as_str().unwrap_or(""),
            ratios.join("/")
        );
        for child in node["children"].as_array().into_iter().flatten() {
            print_tree(child, focused, depth + 1);
        }
        return;
    }
    let mark = if id == focused { "*" } else { " " };
    let content = &node["content"];
    let what = if let Some(tab) = content["tab"].as_str() {
        format!("tab {tab}")
    } else if let Some(file) = content["file"].as_str() {
        format!("file {file}")
    } else {
        "empty".to_owned()
    };
    println!("{indent}{mark} {id}  {what}");
}

fn absolute(path: &str) -> Result<String, CliError> {
    let p = std::path::Path::new(path);
    if p.is_absolute() {
        return Ok(path.to_owned());
    }
    let cwd = std::env::current_dir()
        .map_err(|e| CliError::invalid(format!("can't read the current folder: {e}")))?;
    Ok(cwd.join(p).to_string_lossy().into_owned())
}
