//! Layout and pane commands (PROTOCOL §6.4, PLAN T1.2) and where tabs land in the layout
//! (`tab.focus`, `tab.create` placements, closing a shown tab). The tree edits themselves are the
//! pure functions in `crate::layout`; this module resolves selectors, persists and announces.

use mapo_protocol::hello::Caller;
use mapo_protocol::types::{
    FileOpen, Node, PaneContent, PaneFocus, PaneRef, PaneResize, PaneSplit, SplitContent,
    TabCreate, TabKind,
};
use mapo_protocol::{RpcError, methods, parse_params};
use serde_json::Value;

use super::{Core, to_value};
use crate::layout::{self, Direction, LayoutError};
use crate::model;

/// How many recently focused panes a workspace remembers.
const MRU_LEN: usize = 16;

fn layout_error(e: LayoutError) -> RpcError {
    match e {
        LayoutError::PaneNotFound(_) | LayoutError::SplitNotFound(_) => {
            RpcError::not_found(e.to_string()).with_hint("mapo rpc layout.get")
        }
        LayoutError::BadRatios(_) => RpcError::invalid(e.to_string()),
    }
}

fn contains_node(node: &Node, target: &str) -> bool {
    match node {
        Node::Pane { id, .. } => id == target,
        Node::Split { id, children, .. } => {
            id == target || children.iter().any(|c| contains_node(c, target))
        }
    }
}

/// A terminal pane shows a tab or nothing; file and diff panes are never replaced by a tab.
fn is_terminal(content: Option<&PaneContent>) -> bool {
    matches!(
        content,
        Some(PaneContent::Tab { .. } | PaneContent::Empty { .. })
    )
}

impl Core {
    /// Dispatches `layout.get` and `pane.*`.
    pub(super) fn pane_call(
        &mut self,
        method: &str,
        params: &Value,
        caller: &Caller,
    ) -> Result<Value, RpcError> {
        let ws = match method {
            methods::LAYOUT_GET => {
                let p: PaneRef = parse_params(params)?;
                self.resolve_workspace(p.workspace.as_deref(), caller)?
            }
            methods::PANE_SPLIT => {
                let p: PaneSplit = parse_params(params)?;
                self.pane_split(p, caller)?
            }
            methods::PANE_CLOSE => {
                let p: PaneRef = parse_params(params)?;
                let (ws, pane) =
                    self.pane_target(p.workspace.as_deref(), p.pane.as_deref(), caller)?;
                layout::close(&mut self.workspaces[ws].layout, &pane).map_err(layout_error)?;
                self.layout_changed(ws);
                self.touch_workspace(ws);
                ws
            }
            methods::PANE_FOCUS => {
                let p: PaneFocus = parse_params(params)?;
                self.pane_focus(p, caller)?
            }
            methods::PANE_RESIZE => {
                let p: PaneResize = parse_params(params)?;
                let ws = self.ws_of_node(p.workspace.as_deref(), &p.split)?;
                layout::resize(&mut self.workspaces[ws].layout, &p.split, &p.ratios)
                    .map_err(layout_error)?;
                self.layout_changed(ws);
                ws
            }
            methods::PANE_EQUALIZE => {
                let p: PaneRef = parse_params(params)?;
                let ws = match &p.split {
                    Some(split) => self.ws_of_node(p.workspace.as_deref(), split)?,
                    None => self.resolve_workspace(p.workspace.as_deref(), caller)?,
                };
                layout::equalize(&mut self.workspaces[ws].layout, p.split.as_deref())
                    .map_err(layout_error)?;
                self.layout_changed(ws);
                ws
            }
            methods::PANE_CLEAR_RECENT => {
                let p: PaneRef = parse_params(params)?;
                let (ws, pane) =
                    self.pane_target(p.workspace.as_deref(), p.pane.as_deref(), caller)?;
                layout::clear_recent(&mut self.workspaces[ws].layout, &pane)
                    .map_err(layout_error)?;
                self.layout_changed(ws);
                ws
            }
            other => return Err(RpcError::invalid(format!("unknown method {other}"))),
        };
        to_value(&self.workspaces[ws].layout)
    }

    /// `file.open` (R-LAY-5, UX §6) after the daemon checked that `path` is a readable regular
    /// file: the workspace's file pane shows it, or, with none, a focused empty pane, or a split to
    /// the right of the focused terminal. The file pane gets focus and its workspace activates.
    pub(super) fn file_open(&mut self, p: FileOpen, caller: &Caller) -> Result<Value, RpcError> {
        if !p.path.starts_with('/') {
            return Err(RpcError::invalid(format!(
                "path must be absolute: {}",
                p.path
            )));
        }
        let ws = self.resolve_workspace(p.workspace.as_deref(), caller)?;
        let layout = &self.workspaces[ws].layout;
        let focused = layout.focused_pane_id.clone();
        let pane = match layout::file_pane(layout).map(str::to_owned) {
            Some(pane) => pane,
            None if matches!(
                layout::content(layout, &focused),
                Some(PaneContent::Empty { .. })
            ) || p.beside == Some(false) =>
            {
                focused
            }
            None => {
                // Right of the focused terminal; a focused diff pane defers to the last terminal.
                let target = if is_terminal(layout::content(layout, &focused)) {
                    focused
                } else {
                    self.recent_terminal_pane(ws).unwrap_or(focused)
                };
                let empty = PaneContent::Empty { empty: true };
                let pane = model::new_id();
                layout::split(
                    &mut self.workspaces[ws].layout,
                    &target,
                    Direction::Right,
                    empty,
                    &pane,
                    &model::new_id(),
                )
                .map_err(layout_error)?;
                pane
            }
        };
        let layout = &mut self.workspaces[ws].layout;
        layout::open_file(layout, &pane, &p.path).map_err(layout_error)?;
        layout.focused_pane_id = pane.clone();
        self.activate(ws);
        self.focus_changed(ws);
        Ok(serde_json::json!({ "path": p.path, "paneId": pane }))
    }

    /// The workspace holding pane or split `id`: the `workspace` param's, else any workspace's.
    fn ws_of_node(&self, workspace: Option<&str>, id: &str) -> Result<usize, RpcError> {
        if let Some(sel) = workspace {
            let ws = self.find_workspace(sel)?;
            return if contains_node(&self.workspaces[ws].layout.root, id) {
                Ok(ws)
            } else {
                Err(layout_error(LayoutError::PaneNotFound(id.to_owned())))
            };
        }
        self.workspaces
            .iter()
            .position(|w| contains_node(&w.layout.root, id))
            .ok_or_else(|| {
                RpcError::not_found(format!("no pane or split {id}"))
                    .with_hint("mapo rpc layout.get")
            })
    }

    /// `pane` if given (a pane id), else the focused pane of the resolved workspace (PROTOCOL §5).
    fn pane_target(
        &self,
        workspace: Option<&str>,
        pane: Option<&str>,
        caller: &Caller,
    ) -> Result<(usize, String), RpcError> {
        match pane {
            Some(id) => Ok((self.ws_of_node(workspace, id)?, id.to_owned())),
            None => {
                let ws = self.resolve_workspace(workspace, caller)?;
                Ok((ws, self.workspaces[ws].layout.focused_pane_id.clone()))
            }
        }
    }

    fn pane_split(&mut self, p: PaneSplit, caller: &Caller) -> Result<usize, RpcError> {
        let dir = match p.direction.as_str() {
            "right" => Direction::Right,
            "down" => Direction::Down,
            other => {
                return Err(RpcError::invalid(format!(
                    "direction must be right or down, not \"{other}\""
                )));
            }
        };
        let (ws, target) = self.pane_target(p.workspace.as_deref(), p.pane.as_deref(), caller)?;
        if layout::content(&self.workspaces[ws].layout, &target).is_none() {
            return Err(layout_error(LayoutError::PaneNotFound(target)));
        }
        let content = match p.content {
            None => self.new_shell_in(ws, &target, caller)?,
            Some(SplitContent::Word(w)) if w == "new-shell" => {
                self.new_shell_in(ws, &target, caller)?
            }
            Some(SplitContent::Word(w)) => {
                return Err(RpcError::invalid(format!(
                    "content must be {{tab}}, {{file}} or \"new-shell\", not \"{w}\""
                )));
            }
            Some(SplitContent::File { file }) => {
                if !file.starts_with('/') {
                    return Err(RpcError::invalid(format!("file must be absolute: {file}")));
                }
                PaneContent::File { file }
            }
            Some(SplitContent::Tab { tab }) => {
                let ws_id = self.workspaces[ws].id.clone();
                let t = self.resolve_tab(Some(&tab), Some(&ws_id), caller)?;
                if self.tabs[t].workspace_id != ws_id {
                    return Err(RpcError::invalid(format!(
                        "tab \"{}\" belongs to another workspace",
                        self.tabs[t].name
                    )));
                }
                let tab_id = self.tabs[t].id.clone();
                // A tab shows in one pane at most: move it out of the pane that shows it now.
                if let Some(shown) =
                    layout::pane_of_tab(&self.workspaces[ws].layout, &tab_id).map(str::to_owned)
                {
                    if shown == target {
                        return Err(RpcError::conflict(format!(
                            "tab \"{}\" is already in the pane being split",
                            self.tabs[t].name
                        )));
                    }
                    layout::close(&mut self.workspaces[ws].layout, &shown).map_err(layout_error)?;
                }
                PaneContent::Tab { tab: tab_id }
            }
        };
        self.split_with(ws, &target, dir, content)?;
        Ok(ws)
    }

    /// Splits `target` and puts `content` in the new, focused pane. Persists and announces.
    fn split_with(
        &mut self,
        ws: usize,
        target: &str,
        dir: Direction,
        content: PaneContent,
    ) -> Result<String, RpcError> {
        let pane = model::new_id();
        layout::split(
            &mut self.workspaces[ws].layout,
            target,
            dir,
            content,
            &pane,
            &model::new_id(),
        )
        .map_err(layout_error)?;
        self.remember_focus(ws);
        self.layout_changed(ws);
        self.touch_workspace(ws);
        Ok(pane)
    }

    /// Starts a shell tab for a split of `pane`, in the folder that pane works in.
    fn new_shell_in(
        &mut self,
        ws: usize,
        pane: &str,
        caller: &Caller,
    ) -> Result<PaneContent, RpcError> {
        let cwd = self.pane_cwd(ws, pane);
        let t = self.create_tab(
            TabCreate {
                workspace: Some(self.workspaces[ws].id.clone()),
                kind: Some(TabKind::Shell),
                cwd: Some(cwd),
                placement: Some("background".into()),
                ..Default::default()
            },
            caller,
        )?;
        Ok(PaneContent::Tab {
            tab: self.tabs[t].id.clone(),
        })
    }

    fn pane_focus(&mut self, p: PaneFocus, caller: &Caller) -> Result<usize, RpcError> {
        match (p.pane, p.direction) {
            (Some(_), Some(_)) => Err(RpcError::invalid("pass pane or direction, not both")),
            (Some(pane), None) => {
                let ws = self.ws_of_node(p.workspace.as_deref(), &pane)?;
                layout::focus(&mut self.workspaces[ws].layout, &pane).map_err(layout_error)?;
                self.activate(ws);
                self.focus_changed(ws);
                Ok(ws)
            }
            (None, Some(dir)) => {
                let dir = Direction::parse(&dir).ok_or_else(|| {
                    RpcError::invalid(format!(
                        "direction must be left, right, up or down, not \"{dir}\""
                    ))
                })?;
                let ws = self.resolve_workspace(p.workspace.as_deref(), caller)?;
                let layout = &self.workspaces[ws].layout;
                // Nothing happens at an edge (UX §4.2).
                if let Some(next) = layout::neighbor(layout, &layout.focused_pane_id, dir) {
                    self.workspaces[ws].layout.focused_pane_id = next;
                    self.focus_changed(ws);
                }
                Ok(ws)
            }
            (None, None) => Err(RpcError::invalid("pane.focus needs pane or direction")),
        }
    }

    /// After the focused pane changed: remember it, persist and announce.
    fn focus_changed(&mut self, ws: usize) {
        self.remember_focus(ws);
        self.layout_changed(ws);
        self.touch_workspace(ws);
    }

    /// Records the focused pane as the most recently focused one.
    fn remember_focus(&mut self, ws: usize) {
        let w = &self.workspaces[ws];
        let mru = self.pane_mru.entry(w.id.clone()).or_default();
        let pane = &w.layout.focused_pane_id;
        mru.retain(|p| p != pane);
        mru.push(pane.clone());
        if mru.len() > MRU_LEN {
            mru.remove(0);
        }
    }

    /// The most recently focused terminal pane that still exists.
    fn recent_terminal_pane(&self, ws: usize) -> Option<String> {
        let w = &self.workspaces[ws];
        self.pane_mru
            .get(&w.id)?
            .iter()
            .rev()
            .find_map(|p| is_terminal(layout::content(&w.layout, p)).then(|| p.clone()))
    }

    /// The folder a pane works in: its tab's cwd, or a file's folder. Falls back to the most
    /// recent terminal pane's tab, then `$HOME`.
    pub(super) fn pane_cwd(&self, ws: usize, pane: &str) -> String {
        let layout = &self.workspaces[ws].layout;
        let tab_cwd = |pane: &str| {
            layout::tab_in(layout, pane)
                .and_then(|id| self.tab_index(id))
                .map(|i| self.tabs[i].cwd.clone())
        };
        if let Some(PaneContent::File { file }) = layout::content(layout, pane)
            && let Some(dir) = std::path::Path::new(file).parent()
        {
            return dir.to_string_lossy().into_owned();
        }
        tab_cwd(pane)
            .or_else(|| self.recent_terminal_pane(ws).and_then(|p| tab_cwd(&p)))
            .unwrap_or_else(|| self.home.clone())
    }

    /// The pane a tab goes to when it isn't shown (R-LAY-3): the focused pane, unless it shows a
    /// file or diff; then the most recently focused terminal pane. None means split right.
    fn landing_pane(&self, ws: usize) -> Option<String> {
        let layout = &self.workspaces[ws].layout;
        let focused = &layout.focused_pane_id;
        if is_terminal(layout::content(layout, focused)) {
            return Some(focused.clone());
        }
        self.recent_terminal_pane(ws)
    }

    /// Shows tab `t` in its workspace per `tab.focus` (R-LAY-3) and focuses its pane. Returns
    /// whether the layout changed.
    pub(super) fn show_tab(&mut self, t: usize) -> bool {
        let tab_id = self.tabs[t].id.clone();
        let Some(ws) = self.ws_index(&self.tabs[t].workspace_id) else {
            return false;
        };
        let layout = &mut self.workspaces[ws].layout;
        if let Some(pane) = layout::pane_of_tab(layout, &tab_id).map(str::to_owned) {
            if layout.focused_pane_id == pane {
                return false;
            }
            layout.focused_pane_id = pane;
            self.focus_changed(ws);
            return true;
        }
        let content = PaneContent::Tab { tab: tab_id };
        match self.landing_pane(ws) {
            Some(pane) => {
                let layout = &mut self.workspaces[ws].layout;
                if layout::set_content(layout, &pane, content).is_ok() {
                    layout.focused_pane_id = pane;
                }
                self.focus_changed(ws);
            }
            None => {
                let target = self.workspaces[ws].layout.focused_pane_id.clone();
                let _ = self.split_with(ws, &target, Direction::Right, content);
            }
        }
        true
    }

    /// Puts a just-created tab into the layout per `tab.create`'s placement: `right` and `down`
    /// split the focused pane; `focused` (the default) shows it like `tab.focus` when `focus` is
    /// set or the focused pane is empty; `background` leaves the layout alone.
    pub(super) fn place_new_tab(&mut self, t: usize, placement: Option<&str>, focus: bool) {
        let Some(ws) = self.ws_index(&self.tabs[t].workspace_id) else {
            return;
        };
        let content = PaneContent::Tab {
            tab: self.tabs[t].id.clone(),
        };
        let target = self.workspaces[ws].layout.focused_pane_id.clone();
        match placement {
            Some("background") => {}
            Some("right") => {
                let _ = self.split_with(ws, &target, Direction::Right, content);
            }
            Some("down") => {
                let _ = self.split_with(ws, &target, Direction::Down, content);
            }
            _ => {
                let empty = matches!(
                    layout::content(&self.workspaces[ws].layout, &target),
                    Some(PaneContent::Empty { .. })
                );
                if focus || empty {
                    self.show_tab(t);
                }
            }
        }
    }

    /// Takes a closing tab out of the layout: its pane closes, or turns empty when it is the only
    /// pane (UX §4.2).
    pub(super) fn unshow_tab(&mut self, ws: usize, tab_id: &str) {
        let layout = &mut self.workspaces[ws].layout;
        let Some(pane) = layout::pane_of_tab(layout, tab_id).map(str::to_owned) else {
            return;
        };
        if layout::close(layout, &pane).is_ok() {
            let live = layout::pane_ids(layout);
            if let Some(mru) = self.pane_mru.get_mut(&self.workspaces[ws].id) {
                mru.retain(|p| live.contains(p));
            }
            self.layout_changed(ws);
        }
    }
}
