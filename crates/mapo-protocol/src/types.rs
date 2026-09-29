//! Shared wire types (PROTOCOL §7) and the params of the state methods (PROTOCOL §6.1–§6.3).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Status vocabulary in priority order (REQUIREMENTS R-ST-1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum State {
    NeedsYou,
    Failed,
    Running,
    Done,
    Starting,
    Stopping,
    Idle,
    Stopped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabKind {
    #[serde(alias = "terminal")]
    Shell,
    #[serde(alias = "claude")]
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Launch {
    pub cwd: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_command: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchError {
    /// `cwd_missing`, `cwd_unreadable` or `spawn_failed`.
    pub kind: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LastExit {
    pub code: i32,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabSummary {
    pub id: String,
    pub workspace_id: String,
    pub name: String,
    pub labeled: bool,
    pub title: String,
    pub kind: TabKind,
    pub order: u32,
    pub cwd: String,
    pub launch: Launch,
    pub state: State,
    pub state_label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_detail: Option<String>,
    pub status_source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    pub visible: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_exit: Option<LastExit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_error: Option<LaunchError>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<AgentInfo>,
}

/// Agent facts on a tab (PROTOCOL §7 `TabSummary.agent`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentInfo {
    pub hooks_connected: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default)]
    pub interrupted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct WorkspaceConfigure {
    pub workspace: String,
    #[serde(default)]
    pub agent_command: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSummary {
    pub id: String,
    pub name: String,
    pub order: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_tab_id: Option<String>,
    pub state: State,
    pub state_label: String,
    pub summary: String,
    pub attention_count: u32,
    pub tab_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
}

/// What a pane shows (PROTOCOL §7 `Node` pane content).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum PaneContent {
    Tab { tab: String },
    File { file: String },
    Empty { empty: bool },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Node {
    #[serde(rename_all = "camelCase")]
    Split {
        id: String,
        axis: String,
        ratios: Vec<f64>,
        children: Vec<Node>,
    },
    #[serde(rename_all = "camelCase")]
    Pane {
        id: String,
        content: PaneContent,
        recent_files: Vec<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    pub workspace_id: String,
    pub focused_pane_id: String,
    pub root: Node,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Event {
    pub seq: u64,
    pub boot_id: String,
    /// Milliseconds since the Unix epoch.
    pub at: u64,
    #[serde(rename = "type")]
    pub kind: String,
    pub data: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub seq: u64,
    pub boot_id: String,
    pub active_workspace_id: Option<String>,
    pub workspaces: Vec<WorkspaceSummary>,
    pub tabs: Vec<TabSummary>,
    pub layouts: std::collections::BTreeMap<String, Layout>,
}

// ---- params ----

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SubscribeParams {
    #[serde(default)]
    pub after: Option<u64>,
    #[serde(default)]
    pub types: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct WorkspaceCreate {
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct WorkspaceRef {
    pub workspace: String,
    #[serde(default)]
    pub force: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct WorkspaceRename {
    pub workspace: String,
    pub name: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabListParams {
    #[serde(default)]
    pub workspace: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabCreate {
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub kind: Option<TabKind>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub agent_command: Option<String>,
    #[serde(default)]
    pub placement: Option<String>,
    #[serde(default)]
    pub focus: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabRef {
    #[serde(default)]
    pub tab: Option<String>,
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub force: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabRename {
    #[serde(default)]
    pub tab: Option<String>,
    #[serde(default)]
    pub workspace: Option<String>,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct WorkspaceMove {
    pub workspace: String,
    pub index: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabMove {
    #[serde(default)]
    pub tab: Option<String>,
    #[serde(default)]
    pub workspace: Option<String>,
    pub index: usize,
}

/// `ui.visibility`: what the app shows (app to daemon).
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Visibility {
    pub key_window: bool,
    #[serde(default)]
    pub visible_tab_ids: Vec<String>,
    #[serde(default)]
    pub focused_tab_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabSend {
    #[serde(default)]
    pub tab: Option<String>,
    #[serde(default)]
    pub workspace: Option<String>,
    pub text: String,
    #[serde(default = "yes")]
    pub execute: bool,
    /// `"auto"` (default), `true` or `false`.
    #[serde(default)]
    pub paste: Option<Value>,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabRead {
    #[serde(default)]
    pub tab: Option<String>,
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub lines: Option<usize>,
}

/// `until`: `"idle"` or `{pattern}`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum Until {
    Word(String),
    Pattern { pattern: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabWait {
    #[serde(default)]
    pub tab: Option<String>,
    #[serde(default)]
    pub workspace: Option<String>,
    pub until: Until,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TabRun {
    #[serde(default)]
    pub tab: Option<String>,
    #[serde(default)]
    pub workspace: Option<String>,
    pub command: String,
    #[serde(default)]
    pub lines: Option<usize>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

// ---- layout and panes (PROTOCOL §6.4) ----

/// `layout.get`, `pane.close` and `pane.equalize`. `pane` defaults to the focused pane of the
/// resolved workspace; `split` (equalize only) limits equalizing to one split.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PaneRef {
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub pane: Option<String>,
    #[serde(default)]
    pub split: Option<String>,
}

/// What `pane.split` puts in the new pane: `{tab}`, `{file}` or `"new-shell"` (the default).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum SplitContent {
    Tab { tab: String },
    File { file: String },
    Word(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PaneSplit {
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub pane: Option<String>,
    /// `right` or `down`.
    pub direction: String,
    #[serde(default)]
    pub content: Option<SplitContent>,
}

/// `file.open` (PROTOCOL §6.5): an existing regular file, shown in the workspace's file pane.
/// `beside: false` puts it in the focused pane instead of splitting when there is no file pane.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct FileOpen {
    pub path: String,
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub beside: Option<bool>,
}

/// `pane.focus`: a pane id, or a direction from the focused pane.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PaneFocus {
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub pane: Option<String>,
    #[serde(default)]
    pub direction: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PaneResize {
    #[serde(default)]
    pub workspace: Option<String>,
    pub split: String,
    pub ratios: Vec<f64>,
}
