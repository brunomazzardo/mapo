//! `mapo ui …`: drive the app like a person (ENGINEERING §4.3, PROTOCOL §6.8).

use clap::{Args, Subcommand};
use serde_json::{Value, json};

use super::Cli;
use crate::output::{CliError, print_json};

/// A target: an identifier, `--label`, `--role` with `--label`, or `--point X,Y`.
#[derive(Args, Clone)]
pub struct Target {
    /// Accessibility identifier, e.g. 'rail.tab:Workspace 1/terminal-1'.
    pub id: Option<String>,
    #[arg(long)]
    pub label: Option<String>,
    #[arg(long)]
    pub role: Option<String>,
    /// Window point, top-left origin: X,Y.
    #[arg(long)]
    pub point: Option<String>,
}

impl Target {
    fn to_json(&self) -> Result<Value, CliError> {
        if let Some(p) = &self.point {
            let (x, y) = p
                .split_once(',')
                .and_then(|(x, y)| {
                    Some((x.trim().parse::<f64>().ok()?, y.trim().parse::<f64>().ok()?))
                })
                .ok_or_else(|| CliError::invalid(format!("--point must be X,Y, not {p}")))?;
            return Ok(json!({ "point": { "x": x, "y": y } }));
        }
        match (&self.id, &self.role, &self.label) {
            (Some(id), _, _) => Ok(json!({ "id": id })),
            (None, Some(role), Some(label)) => Ok(json!({ "role": role, "label": label })),
            (None, None, Some(label)) => Ok(json!({ "label": label })),
            _ => Err(CliError::invalid(
                "give a target: an identifier, --label, --role with --label, or --point",
            )),
        }
    }
}

#[derive(Subcommand)]
pub enum UiCommand {
    /// The window's number, frame, scale, title and occlusion.
    Window,
    /// The accessibility element tree.
    Tree {
        #[arg(long)]
        depth: Option<u32>,
    },
    /// What a person could see, as data.
    Snapshot,
    /// Click an element.
    Click {
        #[command(flatten)]
        target: Target,
        #[arg(long)]
        right: bool,
        #[arg(long)]
        count: Option<u32>,
    },
    /// Perform an element's accessibility press.
    Press {
        #[command(flatten)]
        target: Target,
    },
    /// Give an element keyboard focus.
    Focus {
        #[command(flatten)]
        target: Target,
    },
    /// Type text into the focused element.
    Type { text: String },
    /// Press a key chord, e.g. cmd+shift+n or return.
    Key {
        chord: String,
        /// press (default), down or up.
        #[arg(long)]
        phase: Option<String>,
    },
    /// Wait for an element to exist, go away, take focus or become enabled.
    Wait {
        #[command(flatten)]
        target: Target,
        /// exists (default), gone, focused or enabled.
        #[arg(long)]
        state: Option<String>,
    },
    /// Move the synthetic mouse over an element, so its hover affordances show.
    Hover {
        #[command(flatten)]
        target: Target,
    },
    /// Scroll over an element with a scroll-wheel event.
    Scroll {
        #[command(flatten)]
        target: Target,
        /// Points to scroll: positive scrolls the content down (reveals what is below), negative up.
        #[arg(long, allow_negative_numbers = true)]
        dy: f64,
    },
    /// Launch, navigation and attach timings.
    Metrics {
        #[arg(long)]
        reset: bool,
    },
}

pub fn run(cli: &Cli, cmd: &UiCommand) -> Result<(), CliError> {
    let (method, params) = match cmd {
        UiCommand::Window => ("ui.window", json!({})),
        UiCommand::Tree { depth } => (
            "ui.tree",
            depth.map_or(json!({}), |d| json!({ "depth": d })),
        ),
        UiCommand::Snapshot => ("ui.snapshot", json!({})),
        UiCommand::Click {
            target,
            right,
            count,
        } => {
            let mut p = json!({ "target": target.to_json()? });
            if *right {
                p["button"] = json!("right");
            }
            if let Some(c) = count {
                p["count"] = json!(c);
            }
            ("ui.click", p)
        }
        UiCommand::Press { target } => ("ui.press", json!({ "target": target.to_json()? })),
        UiCommand::Focus { target } => ("ui.focus", json!({ "target": target.to_json()? })),
        UiCommand::Type { text } => ("ui.type", json!({ "text": text })),
        UiCommand::Key { chord, phase } => {
            let mut p = json!({ "chord": chord });
            if let Some(ph) = phase {
                p["phase"] = json!(ph);
            }
            ("ui.key", p)
        }
        UiCommand::Wait { target, state } => {
            let mut p =
                json!({ "target": target.to_json()?, "timeoutMs": cli.timeout_ms.unwrap_or(5000) });
            if let Some(s) = state {
                p["state"] = json!(s);
            }
            ("ui.wait", p)
        }
        UiCommand::Hover { target } => ("ui.hover", json!({ "target": target.to_json()? })),
        UiCommand::Scroll { target, dy } => (
            "ui.scroll",
            json!({ "target": target.to_json()?, "dy": dy }),
        ),
        UiCommand::Metrics { reset } => (
            "ui.metrics",
            if *reset {
                json!({ "reset": true })
            } else {
                json!({})
            },
        ),
    };
    let result = cli.connect()?.call(method, params)?;
    print_json(&result, cli.json);
    Ok(())
}
