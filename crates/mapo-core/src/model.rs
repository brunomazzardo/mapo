//! The daemon-side state model (ARCHITECTURE §3.3).

use mapo_protocol::types::{LastExit, Launch, LaunchError, Layout, Node, PaneContent, TabKind};

use crate::status::Facts;

#[derive(Debug, Clone, PartialEq)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub order: u32,
    pub agent_command: Option<String>,
    pub layout: Layout,
    /// The branch of the shown tab's folder, re-read when that folder changes (T1.1).
    pub branch: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Tab {
    pub id: String,
    pub workspace_id: String,
    pub name: String,
    pub labeled: bool,
    /// The live title from OSC 0/2; the name when labeled.
    pub live_title: String,
    pub kind: TabKind,
    pub order: u32,
    pub cwd: String,
    pub launch: Launch,
    pub facts: Facts,
    pub last_exit: Option<LastExit>,
    pub launch_error: Option<LaunchError>,
    pub program: Option<String>,
    /// When the running command's 133;C arrived.
    pub command_started: Option<std::time::Instant>,
}

impl Tab {
    pub fn title(&self) -> String {
        if self.labeled || self.live_title.is_empty() {
            self.name.clone()
        } else {
            self.live_title.clone()
        }
    }
}

pub fn new_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

/// A new workspace's layout: one pane.
pub fn single_pane(workspace_id: &str, tab: Option<&str>) -> Layout {
    let pane = new_id();
    Layout {
        workspace_id: workspace_id.to_owned(),
        focused_pane_id: pane.clone(),
        root: Node::Pane {
            id: pane,
            content: content_for(tab),
            recent_files: vec![],
        },
    }
}

pub fn content_for(tab: Option<&str>) -> PaneContent {
    match tab {
        Some(t) => PaneContent::Tab { tab: t.to_owned() },
        None => PaneContent::Empty { empty: true },
    }
}

/// The tab shown in the layout's focused pane, if any.
pub fn shown_tab(layout: &Layout) -> Option<&str> {
    crate::layout::tab_in(layout, &layout.focused_pane_id)
}

/// Whether `tab` is shown in any pane of the layout.
pub fn shows_tab(layout: &Layout, tab: &str) -> bool {
    crate::layout::pane_of_tab(layout, tab).is_some()
}

/// The focused pane's id.
pub fn pane_id(layout: &Layout) -> &str {
    &layout.focused_pane_id
}
