//! The tool table: one tool per public protocol method (PROTOCOL §10), with hand-written JSON
//! Schemas that mirror the `deny_unknown_fields` param types in `mapo-protocol`.

use serde_json::{Map, Value, json};

/// One MCP tool and the protocol method it calls.
pub struct ToolSpec {
    pub name: &'static str,
    /// The protocol method; `None` for tools computed in the server (`mapo_status`).
    pub method: Option<&'static str>,
    pub description: &'static str,
    pub schema: Value,
    /// Long waits are cancelled when stdin closes; quick calls are allowed to finish.
    pub waits: bool,
}

fn workspace() -> Value {
    json!({"type": "string", "description": "Workspace name or id. Default: your own workspace."})
}

fn workspace_required() -> Value {
    json!({"type": "string", "description": "Workspace name or id."})
}

fn tab() -> Value {
    json!({"type": "string", "description": "Tab name or id. Default: your own tab."})
}

fn timeout_ms() -> Value {
    json!({"type": "integer", "minimum": 0, "description": "Give up after this many milliseconds (error kind `timeout`)."})
}

fn index() -> Value {
    json!({"type": "integer", "minimum": 0, "description": "Zero-based position."})
}

fn pane() -> Value {
    json!({"type": "string", "description": "Pane id. Default: the focused pane."})
}

fn lines() -> Value {
    json!({"type": "integer", "minimum": 1, "description": "How many screen and scrollback lines to return (default 200)."})
}

/// An object schema that rejects unknown properties.
fn object(properties: Value, required: &[&str]) -> Value {
    let mut schema = Map::new();
    schema.insert("type".into(), json!("object"));
    schema.insert("properties".into(), properties);
    if !required.is_empty() {
        schema.insert("required".into(), json!(required));
    }
    schema.insert("additionalProperties".into(), json!(false));
    Value::Object(schema)
}

fn tab_ref() -> Value {
    object(json!({"tab": tab(), "workspace": workspace()}), &[])
}

fn spec(
    name: &'static str,
    method: &'static str,
    description: &'static str,
    schema: Value,
) -> ToolSpec {
    ToolSpec {
        name,
        method: Some(method),
        description,
        schema,
        waits: false,
    }
}

fn waiting(mut tool: ToolSpec) -> ToolSpec {
    tool.waits = true;
    tool
}

/// Every tool `mapo mcp` exposes. No `ui.*`, `app.*`, `hook.*` or `daemon.*` method appears here.
pub fn all() -> Vec<ToolSpec> {
    vec![
        // §6.2 workspaces
        spec(
            "mapo_workspace_list",
            "workspace.list",
            "List Mapo workspaces with their state, attention count and tab count.",
            object(json!({}), &[]),
        ),
        spec(
            "mapo_workspace_create",
            "workspace.create",
            "Create a workspace. Without a name it gets the first free \"Workspace N\".",
            object(json!({"name": {"type": "string"}}), &[]),
        ),
        spec(
            "mapo_workspace_rename",
            "workspace.rename",
            "Rename a workspace.",
            object(
                json!({"workspace": workspace_required(), "name": {"type": "string"}}),
                &["workspace", "name"],
            ),
        ),
        spec(
            "mapo_workspace_activate",
            "workspace.activate",
            "Make a workspace the one the user sees.",
            object(json!({"workspace": workspace_required()}), &["workspace"]),
        ),
        spec(
            "mapo_workspace_delete",
            "workspace.delete",
            "Delete a workspace and close its tabs. Needs force: true when programs are running in it, and from an agent tab always.",
            object(
                json!({"workspace": workspace_required(), "force": {"type": "boolean"}}),
                &["workspace"],
            ),
        ),
        spec(
            "mapo_workspace_move",
            "workspace.move",
            "Move a workspace to a zero-based position in the rail.",
            object(
                json!({"workspace": workspace_required(), "index": index()}),
                &["workspace", "index"],
            ),
        ),
        spec(
            "mapo_workspace_configure",
            "workspace.configure",
            "Set a workspace's agent command (what agent tabs run, default `claude`). Omit agentCommand to clear it.",
            object(
                json!({"workspace": workspace_required(), "agentCommand": {"type": "string"}}),
                &["workspace"],
            ),
        ),
        // §6.3 tabs
        spec(
            "mapo_tab_list",
            "tab.list",
            "List the tabs of a workspace (default: yours) with name, kind, state (idle, running, needs-you, done, failed, stopped), cwd and program.",
            object(json!({"workspace": workspace()}), &[]),
        ),
        spec(
            "mapo_tab_create",
            "tab.create",
            "Create a terminal tab. Name the tabs you create: the name is the stable address for every other tool. kind \"agent\" runs the workspace's agent command through the interactive shell; command runs in the shell after its first prompt. cwd defaults to the focused tab's cwd.",
            object(
                json!({
                    "workspace": workspace(),
                    "name": {"type": "string"},
                    "kind": {"type": "string", "enum": ["shell", "agent", "terminal", "claude"]},
                    "cwd": {"type": "string", "description": "Working directory; relative paths resolve against this server's cwd."},
                    "command": {"type": "string"},
                    "agentCommand": {"type": "string", "description": "Override the agent command for an agent tab."},
                    "placement": {"type": "string", "enum": ["focused", "right", "down", "background"]},
                    "focus": {"type": "boolean"}
                }),
                &[],
            ),
        ),
        spec(
            "mapo_tab_close",
            "tab.close",
            "Close a tab and end its processes. Closing another tab from an agent needs force: true.",
            object(
                json!({"tab": tab(), "workspace": workspace(), "force": {"type": "boolean"}}),
                &[],
            ),
        ),
        spec(
            "mapo_tab_rename",
            "tab.rename",
            "Rename a tab. Names are unique within a workspace.",
            object(
                json!({"tab": tab(), "workspace": workspace(), "name": {"type": "string"}}),
                &["name"],
            ),
        ),
        spec(
            "mapo_tab_focus",
            "tab.focus",
            "Show a tab to the user: activates its workspace and puts it in a pane. Retries a failed launch.",
            tab_ref(),
        ),
        spec(
            "mapo_tab_send",
            "tab.send",
            "Type text into a tab. execute (default true) presses Enter after it; paste uses bracketed paste (default auto: on for multi-line text). To run a shell command and get its output, prefer mapo_tab_run; to prompt another agent and get its reply, prefer mapo_tab_ask.",
            object(
                json!({
                    "tab": tab(),
                    "workspace": workspace(),
                    "text": {"type": "string"},
                    "execute": {"type": "boolean"},
                    "paste": {"enum": [true, false, "auto"]}
                }),
                &["text"],
            ),
        ),
        spec(
            "mapo_tab_read",
            "tab.read",
            "Read a tab's screen and recent scrollback as text.",
            object(
                json!({"tab": tab(), "workspace": workspace(), "lines": lines()}),
                &[],
            ),
        ),
        waiting(spec(
            "mapo_tab_wait",
            "tab.wait",
            "Wait until a tab is idle, or until a regex pattern appears in output written after the last send (or after the wait began). Use this instead of polling mapo_tab_read. Default timeout 600000 ms.",
            object(
                json!({
                    "tab": tab(),
                    "workspace": workspace(),
                    "until": {
                        "anyOf": [
                            {"type": "string", "enum": ["idle"]},
                            object(json!({"pattern": {"type": "string"}}), &["pattern"])
                        ]
                    },
                    "timeoutMs": timeout_ms()
                }),
                &["until"],
            ),
        )),
        waiting(spec(
            "mapo_tab_run",
            "tab.run",
            "Run a shell command in an idle shell tab and return its exit code and output. Fails with kind `busy` when the tab is running something.",
            object(
                json!({
                    "tab": tab(),
                    "workspace": workspace(),
                    "command": {"type": "string"},
                    "lines": lines(),
                    "timeoutMs": timeout_ms()
                }),
                &["command"],
            ),
        )),
        spec(
            "mapo_tab_stop",
            "tab.stop",
            "Send Ctrl-C to a tab's foreground job.",
            tab_ref(),
        ),
        spec(
            "mapo_tab_restart",
            "tab.restart",
            "Restart a stopped tab's shell in its last cwd.",
            tab_ref(),
        ),
        spec(
            "mapo_tab_interrupt",
            "tab.interrupt",
            "Interrupt an agent tab: sends Escape and records the interrupt.",
            tab_ref(),
        ),
        spec(
            "mapo_tab_move",
            "tab.move",
            "Move a tab to a zero-based position in its workspace.",
            object(
                json!({"tab": tab(), "workspace": workspace(), "index": index()}),
                &["index"],
            ),
        ),
        waiting(spec(
            "mapo_tab_ask",
            "tab.ask",
            "Send a prompt to another agent tab, wait for its turn to finish and return its reply. Fails with kind `needs_you` when that agent needs the user. Default timeout 1800000 ms.",
            object(
                json!({
                    "tab": tab(),
                    "workspace": workspace(),
                    "prompt": {"type": "string"},
                    "timeoutMs": timeout_ms()
                }),
                &["prompt"],
            ),
        )),
        // §6.4 layout and panes
        spec(
            "mapo_layout_get",
            "layout.get",
            "Get a workspace's pane layout: splits, panes, what each pane shows and which is focused.",
            object(json!({"workspace": workspace()}), &[]),
        ),
        spec(
            "mapo_pane_split",
            "pane.split",
            "Split a pane to the right or down. content is {tab} to show an existing tab (moving it if shown elsewhere), {file} to open a file, or \"new-shell\".",
            object(
                json!({
                    "workspace": workspace(),
                    "pane": pane(),
                    "direction": {"type": "string", "enum": ["right", "down"]},
                    "content": {
                        "anyOf": [
                            object(json!({"tab": {"type": "string"}}), &["tab"]),
                            object(json!({"file": {"type": "string"}}), &["file"]),
                            {"type": "string", "enum": ["new-shell"]}
                        ]
                    }
                }),
                &["direction"],
            ),
        ),
        spec(
            "mapo_pane_close",
            "pane.close",
            "Close a pane. Its tab keeps running in the background.",
            object(json!({"workspace": workspace(), "pane": pane()}), &[]),
        ),
        spec(
            "mapo_pane_focus",
            "pane.focus",
            "Focus a pane by id, or the neighbor in a direction. Pass pane or direction, not both.",
            object(
                json!({
                    "workspace": workspace(),
                    "pane": pane(),
                    "direction": {"type": "string", "enum": ["left", "right", "up", "down"]}
                }),
                &[],
            ),
        ),
        spec(
            "mapo_pane_resize",
            "pane.resize",
            "Set the ratios of a split's children (split id from mapo_layout_get).",
            object(
                json!({
                    "workspace": workspace(),
                    "split": {"type": "string"},
                    "ratios": {"type": "array", "items": {"type": "number"}}
                }),
                &["split", "ratios"],
            ),
        ),
        spec(
            "mapo_pane_equalize",
            "pane.equalize",
            "Equalize every split in a workspace, or one split.",
            object(
                json!({"workspace": workspace(), "split": {"type": "string"}}),
                &[],
            ),
        ),
        // §6.5 files
        spec(
            "mapo_file_open",
            "file.open",
            "Open an existing file in the workspace's file pane (beside the terminal by default).",
            object(
                json!({
                    "path": {"type": "string", "description": "Relative paths resolve against this server's cwd."},
                    "workspace": workspace(),
                    "beside": {"type": "boolean"}
                }),
                &["path"],
            ),
        ),
        spec(
            "mapo_fs_list",
            "fs.list",
            "List a folder's entries with git status and ignore flags, as the Files inspector shows them.",
            object(
                json!({"path": {"type": "string", "description": "Relative paths resolve against this server's cwd."}}),
                &["path"],
            ),
        ),
        // §6.1 activity and events
        spec(
            "mapo_activity_list",
            "activity.list",
            "The activity log: mutating requests from agents and automation, newest first.",
            object(
                json!({
                    "limit": {"type": "integer", "minimum": 1},
                    "before": {"type": "string", "description": "An activity id; returns older entries."}
                }),
                &[],
            ),
        ),
        waiting(spec(
            "mapo_events_wait",
            "events.wait",
            "Long-poll Mapo events after a sequence number. Returns {events, cursor}; pass cursor as after on the next call. Start with after: 0. Use this instead of polling.",
            object(
                json!({
                    "after": {"type": "integer", "minimum": 0},
                    "timeoutMs": timeout_ms(),
                    "types": {"type": "array", "items": {"type": "string"}, "description": "Only these event types, e.g. tab.state or attention.changed."}
                }),
                &["after"],
            ),
        )),
        ToolSpec {
            name: "mapo_status",
            method: None,
            description: "Tab states at a glance: every tab of a workspace, or one tab when tab is given.",
            schema: object(
                json!({"workspace": workspace(), "tab": {"type": "string", "description": "Tab name or id."}}),
                &[],
            ),
            waits: false,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tools_are_strict_short_and_public() {
        let tools = all();
        let mut names: Vec<_> = tools.iter().map(|t| t.name).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), tools.len());
        for tool in &tools {
            assert!(tool.name.starts_with("mapo_"), "{}", tool.name);
            assert!(tool.description.len() < 2048, "{}", tool.name);
            assert_eq!(
                tool.schema["additionalProperties"],
                json!(false),
                "{}",
                tool.name
            );
            let method = tool.method.unwrap_or("status");
            for group in ["ui.", "app.", "hook.", "daemon."] {
                assert!(!method.starts_with(group), "{}", tool.name);
            }
        }
    }
}
