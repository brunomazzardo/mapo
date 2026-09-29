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

/// The M0 layout: one pane per workspace.
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
    match &layout.root {
        Node::Pane {
            content: PaneContent::Tab { tab },
            ..
        } => Some(tab.as_str()),
        _ => None,
    }
}

/// Points the single pane at `tab` (or empty).
pub fn show_in_pane(layout: &mut Layout, tab: Option<&str>) {
    if let Node::Pane { content, .. } = &mut layout.root {
        *content = content_for(tab);
    }
}

pub fn pane_id(layout: &Layout) -> &str {
    match &layout.root {
        Node::Pane { id, .. } | Node::Split { id, .. } => id,
    }
}
