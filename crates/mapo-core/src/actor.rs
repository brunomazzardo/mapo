//! The core actor: owns workspaces, tabs, layouts and the event ring (PLAN T0.4).

use std::collections::BTreeMap;
use std::path::Path;

use mapo_protocol::hello::{Caller, CredentialKind, Empty};
use mapo_protocol::types::{
    Launch, Snapshot, State, SubscribeParams, TabCreate, TabKind, TabListParams, TabRef, TabRename,
    TabSummary, WorkspaceCreate, WorkspaceRef, WorkspaceRename, WorkspaceSummary,
};
use mapo_protocol::{RpcError, methods, parse_params};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use crate::events::{Ring, SubItem};
use crate::model::{self, Tab, Workspace};
use crate::status::{Facts, status};
use crate::store::{self, Write};

type Reply<T> = oneshot::Sender<Result<T, RpcError>>;

/// What the process host (mapo-term, wired by the daemon) must start for a tab.
#[derive(Debug, Clone)]
pub struct LaunchSpec {
    pub tab_id: String,
    pub workspace_id: String,
    pub name: String,
    pub kind: TabKind,
    pub cwd: String,
    pub command: Option<String>,
    /// The tab's `MAPO_TOKEN`; never log it.
    pub token: String,
    pub hook_token: String,
}

/// Commands from the core to the process host.
#[derive(Debug, Clone)]
pub enum HostCmd {
    Launch(LaunchSpec),
    Close { tab_id: String },
}

/// OSC 133 marks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mark {
    PromptStart,
    PromptEnd,
    CommandStart,
    CommandEnd(Option<i32>),
}

/// Facts the process host reports about a tab.
#[derive(Debug, Clone, PartialEq)]
pub enum TabFact {
    Spawned,
    /// The shell reached its first prompt, or 3 s passed without integration.
    Ready,
    LaunchFailed(mapo_protocol::types::LaunchError),
    Cwd(String),
    Title(String),
    Mark(Mark),
    Exited {
        code: i32,
        after_prompt: bool,
        duration_ms: u64,
    },
}

pub struct Subscription {
    pub seq: u64,
    pub replay: Vec<mapo_protocol::types::Event>,
    pub live: mpsc::Receiver<SubItem>,
}

enum Msg {
    Call {
        method: String,
        params: Value,
        caller: Caller,
        reply: Reply<Value>,
    },
    Subscribe {
        params: SubscribeParams,
        reply: Reply<Subscription>,
    },
    Emit {
        kind: String,
        data: Value,
    },
    Fact {
        tab_id: String,
        fact: TabFact,
    },
    Authenticate {
        token: String,
        reply: oneshot::Sender<Option<Caller>>,
    },
    Resolve {
        tab: Option<String>,
        workspace: Option<String>,
        caller: Caller,
        reply: Reply<TabSummary>,
    },
    Flush {
        reply: oneshot::Sender<()>,
    },
}

/// A cheap, cloneable handle to the actor.
#[derive(Clone)]
pub struct CoreHandle {
    tx: mpsc::UnboundedSender<Msg>,
}

fn gone() -> RpcError {
    RpcError::unavailable("the daemon is shutting down")
}

impl CoreHandle {
    /// Whether `method` is handled by the core.
    pub fn handles(method: &str) -> bool {
        matches!(
            method,
            methods::STATE_SNAPSHOT
                | methods::WORKSPACE_LIST
                | methods::WORKSPACE_CREATE
                | methods::WORKSPACE_RENAME
                | methods::WORKSPACE_ACTIVATE
                | methods::WORKSPACE_DELETE
                | methods::TAB_LIST
                | methods::TAB_CREATE
                | methods::TAB_CLOSE
                | methods::TAB_RENAME
                | methods::TAB_FOCUS
        )
    }

    pub async fn call(
        &self,
        method: &str,
        params: Value,
        caller: Caller,
    ) -> Result<Value, RpcError> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Msg::Call {
                method: method.to_owned(),
                params,
                caller,
                reply,
            })
            .map_err(|_| gone())?;
        rx.await.map_err(|_| gone())?
    }

    pub async fn subscribe(&self, params: SubscribeParams) -> Result<Subscription, RpcError> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Msg::Subscribe { params, reply })
            .map_err(|_| gone())?;
        rx.await.map_err(|_| gone())?
    }

    /// Reports a fact about a tab from the process host.
    pub fn tab_fact(&self, tab_id: &str, fact: TabFact) {
        let _ = self.tx.send(Msg::Fact {
            tab_id: tab_id.to_owned(),
            fact,
        });
    }

    /// The caller for a tab token (`MAPO_TOKEN`), if it belongs to a live tab.
    pub async fn authenticate_tab(&self, token: &str) -> Option<Caller> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Msg::Authenticate {
                token: token.to_owned(),
                reply,
            })
            .ok()?;
        rx.await.ok().flatten()
    }

    /// Resolves a tab selector the way every tab method does (PROTOCOL §5).
    pub async fn resolve_tab(
        &self,
        tab: Option<String>,
        workspace: Option<String>,
        caller: Caller,
    ) -> Result<TabSummary, RpcError> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .send(Msg::Resolve {
                tab,
                workspace,
                caller,
                reply,
            })
            .map_err(|_| gone())?;
        rx.await.map_err(|_| gone())?
    }

    pub fn emit(&self, kind: &str, data: Value) {
        let _ = self.tx.send(Msg::Emit {
            kind: kind.to_owned(),
            data,
        });
    }

    /// Waits until every write so far is committed.
    pub async fn flush(&self) {
        let (reply, rx) = oneshot::channel();
        if self.tx.send(Msg::Flush { reply }).is_ok() {
            let _ = rx.await;
        }
    }
}

/// Options for starting the core.
pub struct Options<'a> {
    pub state_db: &'a Path,
    pub boot_id: String,
    pub home: String,
    pub host: mpsc::UnboundedSender<HostCmd>,
}

/// Opens the database, loads state and starts the actor on the current tokio runtime.
pub fn spawn(opts: Options<'_>) -> Result<CoreHandle, store::StoreError> {
    let conn = store::open(opts.state_db)?;
    let loaded = store::load(&conn)?;
    let writer = store::spawn_writer(conn);
    let mut core = Core {
        workspaces: loaded.workspaces,
        tabs: loaded.tabs,
        active: loaded.active_workspace,
        ring: Ring::new(opts.boot_id),
        writer,
        pending: Vec::new(),
        home: opts.home,
        host: opts.host,
        tokens: Default::default(),
    };
    if core
        .active
        .as_ref()
        .is_none_or(|a| core.ws_index(a).is_none())
    {
        core.active = core.workspaces.first().map(|w| w.id.clone());
    }
    for t in 0..core.tabs.len() {
        core.launch(t);
    }
    let (tx, mut rx) = mpsc::unbounded_channel::<Msg>();
    tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            core.handle(msg);
            core.commit();
        }
        core.commit();
    });
    Ok(CoreHandle { tx })
}

struct Core {
    workspaces: Vec<Workspace>,
    tabs: Vec<Tab>,
    active: Option<String>,
    ring: Ring,
    writer: std::sync::mpsc::Sender<Vec<Write>>,
    pending: Vec<Write>,
    home: String,
    host: mpsc::UnboundedSender<HostCmd>,
    /// Tab token → tab id. Revoked when the tab closes; new on every launch.
    tokens: std::collections::HashMap<String, String>,
}

impl Core {
    fn handle(&mut self, msg: Msg) {
        match msg {
            Msg::Call {
                method,
                params,
                caller,
                reply,
            } => {
                let _ = reply.send(self.dispatch(&method, &params, &caller));
            }
            Msg::Subscribe { params, reply } => {
                let result = self
                    .ring
                    .subscribe(params.after, params.types)
                    .map(|(seq, replay, live)| Subscription { seq, replay, live });
                let _ = reply.send(result);
            }
            Msg::Emit { kind, data } => self.ring.push(&kind, data),
            Msg::Fact { tab_id, fact } => self.fact(&tab_id, fact),
            Msg::Authenticate { token, reply } => {
                let caller = self
                    .tokens
                    .get(&token)
                    .and_then(|id| self.tab_index(id))
                    .map(|t| Caller {
                        kind: CredentialKind::Tab,
                        tab_id: Some(self.tabs[t].id.clone()),
                        workspace_id: Some(self.tabs[t].workspace_id.clone()),
                    });
                let _ = reply.send(caller);
            }
            Msg::Resolve {
                tab,
                workspace,
                caller,
                reply,
            } => {
                let r = self
                    .resolve_tab(tab.as_deref(), workspace.as_deref(), &caller)
                    .map(|t| self.tab_summary(&self.tabs[t]));
                let _ = reply.send(r);
            }
            Msg::Flush { reply } => {
                self.commit();
                let (done, wait) = std::sync::mpsc::channel();
                let _ = self.writer.send(vec![Write::Flush(done)]);
                std::thread::spawn(move || {
                    let _ = wait.recv();
                    let _ = reply.send(());
                });
            }
        }
    }

    fn commit(&mut self) {
        if !self.pending.is_empty() {
            let batch = std::mem::take(&mut self.pending);
            let _ = self.writer.send(batch);
        }
    }

    fn dispatch(
        &mut self,
        method: &str,
        params: &Value,
        caller: &Caller,
    ) -> Result<Value, RpcError> {
        match method {
            methods::STATE_SNAPSHOT => {
                let _: Empty = parse_params(params)?;
                to_value(&self.snapshot())
            }
            methods::WORKSPACE_LIST => {
                let _: Empty = parse_params(params)?;
                to_value(
                    &self
                        .workspaces
                        .iter()
                        .map(|w| self.ws_summary(w))
                        .collect::<Vec<_>>(),
                )
            }
            methods::WORKSPACE_CREATE => {
                let p: WorkspaceCreate = parse_params(params)?;
                let idx = self.create_workspace(p.name)?;
                to_value(&self.ws_summary(&self.workspaces[idx]))
            }
            methods::WORKSPACE_RENAME => {
                let p: WorkspaceRename = parse_params(params)?;
                let idx = self.find_workspace(&p.workspace)?;
                let name = non_empty(&p.name, "workspace name")?;
                self.workspaces[idx].name = name;
                self.touch_workspace(idx);
                to_value(&self.ws_summary(&self.workspaces[idx]))
            }
            methods::WORKSPACE_ACTIVATE => {
                let p: WorkspaceRef = parse_params(params)?;
                let idx = self.find_workspace(&p.workspace)?;
                self.activate(idx);
                to_value(&self.ws_summary(&self.workspaces[idx]))
            }
            methods::WORKSPACE_DELETE => {
                let p: WorkspaceRef = parse_params(params)?;
                let idx = self.find_workspace(&p.workspace)?;
                self.delete_workspace(idx, p.force)?;
                Ok(json!({ "deleted": true }))
            }
            methods::TAB_LIST => {
                let p: TabListParams = parse_params(params)?;
                let ws = self.resolve_workspace(p.workspace.as_deref(), caller)?;
                let ws_id = self.workspaces[ws].id.clone();
                to_value(
                    &self
                        .tabs_of(&ws_id)
                        .map(|t| self.tab_summary(t))
                        .collect::<Vec<_>>(),
                )
            }
            methods::TAB_CREATE => {
                let p: TabCreate = parse_params(params)?;
                let t = self.create_tab(p, caller)?;
                to_value(&self.tab_summary(&self.tabs[t]))
            }
            methods::TAB_CLOSE => {
                let p: TabRef = parse_params(params)?;
                let t = self.resolve_tab(p.tab.as_deref(), p.workspace.as_deref(), caller)?;
                self.close_tab(t, p.force)?;
                Ok(json!({ "closed": true }))
            }
            methods::TAB_RENAME => {
                let p: TabRename = parse_params(params)?;
                let t = self.resolve_tab(p.tab.as_deref(), p.workspace.as_deref(), caller)?;
                let name = non_empty(&p.name, "tab name")?;
                let ws = self.tabs[t].workspace_id.clone();
                if self
                    .tabs
                    .iter()
                    .any(|o| o.workspace_id == ws && o.name == name && o.id != self.tabs[t].id)
                {
                    return Err(RpcError::conflict(format!(
                        "a tab named \"{name}\" already exists in this workspace"
                    )));
                }
                self.tabs[t].name = name;
                self.tabs[t].labeled = true;
                self.touch_tab(t);
                to_value(&self.tab_summary(&self.tabs[t]))
            }
            methods::TAB_FOCUS => {
                let p: TabRef = parse_params(params)?;
                let t = self.resolve_tab(p.tab.as_deref(), p.workspace.as_deref(), caller)?;
                self.focus_tab(t);
                to_value(&self.tab_summary(&self.tabs[t]))
            }
            other => Err(RpcError::invalid(format!("unknown method {other}"))),
        }
    }

    // ---- lookups ----

    fn ws_index(&self, id: &str) -> Option<usize> {
        self.workspaces.iter().position(|w| w.id == id)
    }

    fn tab_index(&self, id: &str) -> Option<usize> {
        self.tabs.iter().position(|t| t.id == id)
    }

    fn tabs_of<'a>(&'a self, ws_id: &'a str) -> impl Iterator<Item = &'a Tab> + 'a {
        let mut v: Vec<&Tab> = self
            .tabs
            .iter()
            .filter(|t| t.workspace_id == ws_id)
            .collect();
        v.sort_by_key(|t| t.order);
        v.into_iter()
    }

    /// A workspace by id or name; an ambiguous name is a conflict.
    fn find_workspace(&self, sel: &str) -> Result<usize, RpcError> {
        if let Some(i) = self.ws_index(sel) {
            return Ok(i);
        }
        let hits: Vec<usize> = (0..self.workspaces.len())
            .filter(|&i| self.workspaces[i].name == sel)
            .collect();
        match hits.as_slice() {
            [i] => Ok(*i),
            [] => Err(RpcError::not_found(format!("Workspace \"{sel}\" not found"))
                .with_hint("mapo workspace list")
                .with_details(json!({ "names": self.workspaces.iter().map(|w| &w.name).collect::<Vec<_>>() }))),
            _ => Err(RpcError::conflict(format!("more than one workspace is named \"{sel}\"; use an id"))
                .with_details(json!({ "ids": hits.iter().map(|&i| &self.workspaces[i].id).collect::<Vec<_>>() }))),
        }
    }

    /// The `workspace` param, else the caller's workspace, else the active one (PROTOCOL §5).
    fn resolve_workspace(&self, sel: Option<&str>, caller: &Caller) -> Result<usize, RpcError> {
        if let Some(sel) = sel {
            return self.find_workspace(sel);
        }
        let id = caller.workspace_id.as_ref().or(self.active.as_ref());
        id.and_then(|id| self.ws_index(id)).ok_or_else(|| {
            RpcError::not_found("there is no workspace yet").with_hint("mapo workspace new")
        })
    }

    fn resolve_tab(
        &self,
        tab: Option<&str>,
        ws: Option<&str>,
        caller: &Caller,
    ) -> Result<usize, RpcError> {
        let Some(sel) = tab else {
            if caller.kind == CredentialKind::Tab
                && let Some(id) = &caller.tab_id
                && let Some(i) = self.tab_index(id)
            {
                return Ok(i);
            }
            return Err(RpcError::invalid("tab is required"));
        };
        if let Some(i) = self.tab_index(sel) {
            return Ok(i);
        }
        let w = self.resolve_workspace(ws, caller)?;
        let ws = &self.workspaces[w];
        self.tabs
            .iter()
            .position(|t| t.workspace_id == ws.id && t.name == sel)
            .ok_or_else(|| {
                let names: Vec<&str> = self.tabs_of(&ws.id).map(|t| t.name.as_str()).collect();
                RpcError::not_found(format!(
                    "Tab \"{sel}\" not found in workspace \"{}\"",
                    ws.name
                ))
                .with_hint(format!("mapo tab list --workspace '{}'", ws.name))
                .with_details(json!({ "names": names }))
            })
    }

    // ---- summaries ----

    fn tab_summary(&self, t: &Tab) -> TabSummary {
        let (state, label) = status(&t.facts);
        let ws = self.ws_index(&t.workspace_id).map(|i| &self.workspaces[i]);
        let shown = ws.is_some_and(|w| model::shown_tab(&w.layout) == Some(t.id.as_str()));
        TabSummary {
            id: t.id.clone(),
            workspace_id: t.workspace_id.clone(),
            name: t.name.clone(),
            labeled: t.labeled,
            title: t.title(),
            kind: t.kind,
            order: t.order,
            cwd: t.cwd.clone(),
            launch: t.launch.clone(),
            state,
            state_label: label,
            state_detail: t.launch_error.as_ref().map(|e| e.message.clone()),
            status_source: "shell".into(),
            program: t.program.clone(),
            visible: shown && self.active.as_deref() == Some(t.workspace_id.as_str()),
            pane_id: if shown {
                ws.map(|w| model::pane_id(&w.layout).to_owned())
            } else {
                None
            },
            last_exit: t.last_exit,
            launch_error: t.launch_error.clone(),
        }
    }

    fn ws_summary(&self, w: &Workspace) -> WorkspaceSummary {
        let tabs: Vec<TabSummary> = self.tabs_of(&w.id).map(|t| self.tab_summary(t)).collect();
        let top = tabs
            .iter()
            .filter(|t| {
                matches!(
                    t.state,
                    State::NeedsYou | State::Failed | State::Running | State::Done
                )
            })
            .min_by_key(|t| t.state);
        WorkspaceSummary {
            id: w.id.clone(),
            name: w.name.clone(),
            order: w.order,
            agent_command: w.agent_command.clone(),
            active_tab_id: model::shown_tab(&w.layout).map(str::to_owned),
            state: top.map_or(State::Idle, |t| t.state),
            state_label: top.map_or_else(String::new, |t| t.state_label.clone()),
            summary: String::new(),
            attention_count: tabs.iter().filter(|t| t.state == State::NeedsYou).count() as u32,
            tab_count: tabs.len() as u32,
            branch: None,
        }
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            seq: self.ring.seq(),
            boot_id: self.ring.boot_id().to_owned(),
            active_workspace_id: self.active.clone(),
            workspaces: self.workspaces.iter().map(|w| self.ws_summary(w)).collect(),
            tabs: self
                .workspaces
                .iter()
                .flat_map(|w| self.tabs_of(&w.id).map(|t| self.tab_summary(t)))
                .collect(),
            layouts: self
                .workspaces
                .iter()
                .map(|w| (w.id.clone(), w.layout.clone()))
                .collect::<BTreeMap<_, _>>(),
        }
    }

    // ---- mutations (each persists and emits) ----

    fn touch_workspace(&mut self, idx: usize) {
        let w = &self.workspaces[idx];
        self.pending.push(Write::Workspace(w.clone()));
        let summary = self.ws_summary(w);
        self.ring.push("workspace.updated", json!(summary));
    }

    fn touch_tab(&mut self, t: usize) {
        self.pending.push(Write::Tab(self.tabs[t].clone()));
        let summary = self.tab_summary(&self.tabs[t]);
        self.ring.push("tab.updated", json!(summary));
    }

    fn layout_changed(&mut self, idx: usize) {
        self.pending
            .push(Write::Workspace(self.workspaces[idx].clone()));
        self.ring
            .push("layout.updated", json!(self.workspaces[idx].layout));
    }

    fn create_workspace(&mut self, name: Option<String>) -> Result<usize, RpcError> {
        let name = match name {
            Some(n) => non_empty(&n, "workspace name")?,
            None => {
                crate::names::first_free_workspace(self.workspaces.iter().map(|w| w.name.as_str()))
            }
        };
        let id = model::new_id();
        let order = self
            .workspaces
            .iter()
            .map(|w| w.order + 1)
            .max()
            .unwrap_or(0);
        self.workspaces.push(Workspace {
            layout: model::single_pane(&id, None),
            id,
            name,
            order,
            agent_command: None,
        });
        let idx = self.workspaces.len() - 1;
        self.pending
            .push(Write::Workspace(self.workspaces[idx].clone()));
        self.ring.push(
            "workspace.created",
            json!(self.ws_summary(&self.workspaces[idx])),
        );
        if self.active.is_none() {
            self.activate(idx);
        }
        Ok(idx)
    }

    fn activate(&mut self, idx: usize) {
        let id = self.workspaces[idx].id.clone();
        if self.active.as_deref() == Some(id.as_str()) {
            return;
        }
        self.active = Some(id.clone());
        self.pending
            .push(Write::Meta("active_workspace".into(), id.clone()));
        self.ring.push("workspace.activated", json!({ "id": id }));
    }

    fn busy_tab(&self, t: &Tab) -> bool {
        t.facts.in_command || t.program.is_some()
    }

    fn delete_workspace(&mut self, idx: usize, force: bool) -> Result<(), RpcError> {
        let id = self.workspaces[idx].id.clone();
        if !force
            && self
                .tabs
                .iter()
                .any(|t| t.workspace_id == id && self.busy_tab(t))
        {
            return Err(RpcError::forbidden(format!(
                "workspace \"{}\" has a running program; pass --force to delete it anyway",
                self.workspaces[idx].name
            )));
        }
        let closing: Vec<String> = self
            .tabs
            .iter()
            .filter(|t| t.workspace_id == id)
            .map(|t| t.id.clone())
            .collect();
        self.tabs.retain(|t| t.workspace_id != id);
        for tab in &closing {
            self.tokens.retain(|_, t| t != tab);
            let _ = self.host.send(HostCmd::Close {
                tab_id: tab.clone(),
            });
        }
        for tab in &closing {
            self.ring
                .push("tab.closed", json!({ "id": tab, "workspaceId": id }));
        }
        self.workspaces.remove(idx);
        self.pending.push(Write::DeleteWorkspace(id.clone()));
        self.ring.push("workspace.deleted", json!({ "id": id }));
        if self.active.as_deref() == Some(id.as_str()) {
            self.active = None;
            let next = idx.min(self.workspaces.len().saturating_sub(1));
            if !self.workspaces.is_empty() {
                self.activate(next);
            } else {
                self.pending
                    .push(Write::Meta("active_workspace".into(), String::new()));
            }
        }
        Ok(())
    }

    fn create_tab(&mut self, p: TabCreate, caller: &Caller) -> Result<usize, RpcError> {
        let ws = match (p.workspace.as_deref(), &caller.workspace_id, &self.active) {
            (None, None, None) => self.create_workspace(None)?,
            _ => self.resolve_workspace(p.workspace.as_deref(), caller)?,
        };
        let ws_id = self.workspaces[ws].id.clone();
        let kind = p.kind.unwrap_or(TabKind::Shell);
        let (name, labeled) = match p.name {
            Some(n) => (non_empty(&n, "tab name")?, true),
            None => {
                let prefix = if kind == TabKind::Agent {
                    "agent-"
                } else {
                    "terminal-"
                };
                let taken: Vec<&str> = self.tabs_of(&ws_id).map(|t| t.name.as_str()).collect();
                (crate::names::first_free(prefix, taken), false)
            }
        };
        if self
            .tabs
            .iter()
            .any(|t| t.workspace_id == ws_id && t.name == name)
        {
            return Err(RpcError::conflict(format!(
                "a tab named \"{name}\" already exists in workspace \"{}\"",
                self.workspaces[ws].name
            ))
            .with_hint("pick another --name"));
        }
        let cwd = match p.cwd {
            Some(c) if !c.starts_with('/') => {
                return Err(RpcError::invalid(format!("cwd must be absolute: {c}")));
            }
            Some(c) => c,
            None => model::shown_tab(&self.workspaces[ws].layout)
                .and_then(|id| self.tab_index(id))
                .map(|i| self.tabs[i].cwd.clone())
                .unwrap_or_else(|| self.home.clone()),
        };
        let order = self.tabs_of(&ws_id).map(|t| t.order + 1).max().unwrap_or(0);
        let tab = Tab {
            id: model::new_id(),
            workspace_id: ws_id,
            live_title: String::new(),
            labeled,
            name,
            kind,
            order,
            cwd: cwd.clone(),
            launch: Launch {
                cwd,
                command: p.command,
                agent_command: p.agent_command,
            },
            facts: Facts {
                kind: Some(kind),
                ..Default::default()
            },
            last_exit: None,
            launch_error: None,
            program: None,
        };
        self.tabs.push(tab);
        let t = self.tabs.len() - 1;
        self.pending.push(Write::Tab(self.tabs[t].clone()));
        let focus = p.focus.unwrap_or(false) && p.placement.as_deref() != Some("background");
        let pane_empty = model::shown_tab(&self.workspaces[ws].layout).is_none();
        if focus || (pane_empty && p.placement.as_deref() != Some("background")) {
            model::show_in_pane(&mut self.workspaces[ws].layout, Some(&self.tabs[t].id));
            self.layout_changed(ws);
        }
        self.launch(t);
        self.ring
            .push("tab.created", json!(self.tab_summary(&self.tabs[t])));
        if focus {
            self.activate(ws);
        }
        self.touch_workspace(ws);
        Ok(t)
    }

    fn close_tab(&mut self, t: usize, force: bool) -> Result<(), RpcError> {
        if !force && self.busy_tab(&self.tabs[t]) {
            return Err(RpcError::forbidden(format!(
                "tab \"{}\" is running a program; pass --force to close it anyway",
                self.tabs[t].name
            )));
        }
        let tab = self.tabs.remove(t);
        self.tokens.retain(|_, id| *id != tab.id);
        let _ = self.host.send(HostCmd::Close {
            tab_id: tab.id.clone(),
        });
        self.pending.push(Write::DeleteTab(tab.id.clone()));
        self.ring.push(
            "tab.closed",
            json!({ "id": tab.id, "workspaceId": tab.workspace_id }),
        );
        if let Some(ws) = self.ws_index(&tab.workspace_id) {
            if model::shown_tab(&self.workspaces[ws].layout) == Some(tab.id.as_str()) {
                let siblings: Vec<&Tab> = self.tabs_of(&tab.workspace_id).collect();
                let next = siblings
                    .iter()
                    .find(|s| s.order > tab.order)
                    .or(siblings.last())
                    .map(|s| s.id.clone());
                model::show_in_pane(&mut self.workspaces[ws].layout, next.as_deref());
                self.layout_changed(ws);
            }
            self.touch_workspace(ws);
        }
        Ok(())
    }

    fn focus_tab(&mut self, t: usize) {
        if self.tabs[t].launch_error.is_some() && !self.tabs[t].facts.spawning {
            self.launch(t);
            self.touch_tab(t);
        }
        let ws_id = self.tabs[t].workspace_id.clone();
        let Some(ws) = self.ws_index(&ws_id) else {
            return;
        };
        self.activate(ws);
        if model::shown_tab(&self.workspaces[ws].layout) != Some(self.tabs[t].id.as_str()) {
            model::show_in_pane(&mut self.workspaces[ws].layout, Some(&self.tabs[t].id));
            self.layout_changed(ws);
            self.touch_workspace(ws);
        }
    }
}

impl Core {
    /// Starts the tab's process, one launch at a time (contract 1).
    fn launch(&mut self, t: usize) {
        if self.tabs[t].facts.spawning {
            return;
        }
        let token = new_token();
        let hook_token = new_token();
        self.tokens.retain(|_, id| *id != self.tabs[t].id);
        self.tokens.insert(token.clone(), self.tabs[t].id.clone());
        let tab = &mut self.tabs[t];
        tab.launch_error = None;
        tab.last_exit = None;
        tab.facts = Facts {
            kind: Some(tab.kind),
            spawning: true,
            ..Default::default()
        };
        let _ = self.host.send(HostCmd::Launch(LaunchSpec {
            tab_id: tab.id.clone(),
            workspace_id: tab.workspace_id.clone(),
            name: tab.name.clone(),
            kind: tab.kind,
            cwd: tab.cwd.clone(),
            command: tab.launch.command.clone(),
            token,
            hook_token,
        }));
    }

    fn fact(&mut self, tab_id: &str, fact: TabFact) {
        let Some(t) = self.tab_index(tab_id) else {
            return;
        };
        let before = status(&self.tabs[t].facts);
        let mut persist = false;
        let tab = &mut self.tabs[t];
        match fact {
            TabFact::Spawned => {}
            TabFact::Ready => tab.facts.spawning = false,
            TabFact::LaunchFailed(err) => {
                tab.facts.spawning = false;
                tab.facts.launch_error = true;
                tab.launch_error = Some(err);
                self.tokens.retain(|_, id| id != tab_id);
            }
            TabFact::Cwd(cwd) => {
                if tab.cwd != cwd {
                    tab.cwd = cwd;
                    persist = true;
                }
            }
            TabFact::Title(title) => tab.live_title = title,
            TabFact::Mark(Mark::PromptStart | Mark::PromptEnd) => {
                tab.facts.spawning = false;
                tab.facts.in_command = false;
            }
            TabFact::Mark(Mark::CommandStart) => {
                tab.facts.spawning = false;
                tab.facts.in_command = true;
                tab.facts.last_command_failed = None;
            }
            TabFact::Mark(Mark::CommandEnd(code)) => {
                tab.facts.in_command = false;
                tab.facts.last_command_failed = code.filter(|c| *c != 0);
            }
            TabFact::Exited {
                code,
                after_prompt,
                duration_ms,
            } => {
                self.tokens.retain(|_, id| id != tab_id);
                // R-TAB-12: a clean exit after the first prompt closes the tab, as terminals do.
                if code == 0 && after_prompt {
                    let _ = self.close_tab(t, true);
                    return;
                }
                let tab = &mut self.tabs[t];
                tab.facts = Facts {
                    kind: Some(tab.kind),
                    stopped_exit: Some(code),
                    ..Default::default()
                };
                tab.last_exit = Some(mapo_protocol::types::LastExit { code, duration_ms });
            }
        }
        if persist {
            self.pending.push(Write::Tab(self.tabs[t].clone()));
        }
        let after = status(&self.tabs[t].facts);
        let summary = self.tab_summary(&self.tabs[t]);
        self.ring.push("tab.updated", json!(summary));
        if after.0 != before.0 {
            self.ring.push(
                "tab.state",
                json!({ "tabId": summary.id, "workspaceId": summary.workspace_id, "state": after.0,
                        "previous": before.0, "stateLabel": after.1, "source": "shell" }),
            );
            if let Some(ws) = self.ws_index(&summary.workspace_id) {
                let ws_summary = self.ws_summary(&self.workspaces[ws]);
                self.ring.push("workspace.updated", json!(ws_summary));
            }
        }
    }
}

/// 32 random bytes, base64url (PROTOCOL §3).
fn new_token() -> String {
    mapo_instance::Secret::generate()
        .map(|s| s.expose().to_owned())
        .unwrap_or_else(|_| uuid::Uuid::now_v7().simple().to_string())
}

fn non_empty(s: &str, what: &str) -> Result<String, RpcError> {
    let t = s.trim();
    if t.is_empty() {
        return Err(RpcError::invalid(format!("{what} must not be empty")));
    }
    Ok(t.to_owned())
}

fn to_value(v: &impl serde::Serialize) -> Result<Value, RpcError> {
    serde_json::to_value(v).map_err(|e| RpcError::internal(e.to_string()))
}
