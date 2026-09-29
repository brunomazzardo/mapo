//! One canonical example per wire type (ENGINEERING §8). `UPDATE_FIXTURES=1` rewrites them;
//! MapoProtocolTests decodes the same files on the Swift side.
#![allow(clippy::unwrap_used)]

use std::collections::BTreeMap;
use std::path::PathBuf;

use mapo_protocol::RpcError;
use mapo_protocol::hello::{Caller, Credential, CredentialKind, HelloParams, HelloResult, Role};
use mapo_protocol::types::{
    Event, Launch, Layout, Node, PaneContent, Snapshot, State, TabKind, TabSummary,
    WorkspaceSummary,
};
use serde_json::{Value, json};

const WS: &str = "0199a3c1-0000-7000-8000-000000000001";
const TAB: &str = "0199a3c2-0000-7000-8000-000000000002";
const PANE: &str = "0199a3c3-0000-7000-8000-000000000003";
const BOOT: &str = "0199a3c0-0000-7000-8000-000000000000";

fn tab() -> TabSummary {
    TabSummary {
        id: TAB.into(),
        workspace_id: WS.into(),
        name: "be".into(),
        labeled: true,
        title: "be".into(),
        kind: TabKind::Shell,
        order: 0,
        cwd: "/usr/bin".into(),
        launch: Launch {
            cwd: "/usr/bin".into(),
            command: None,
            agent_command: None,
        },
        state: State::Idle,
        state_label: String::new(),
        state_detail: None,
        status_source: "shell".into(),
        program: None,
        visible: true,
        pane_id: Some(PANE.into()),
        last_exit: None,
        launch_error: None,
    }
}

fn workspace() -> WorkspaceSummary {
    WorkspaceSummary {
        id: WS.into(),
        name: "Obsess".into(),
        order: 0,
        agent_command: None,
        active_tab_id: Some(TAB.into()),
        state: State::Idle,
        state_label: String::new(),
        summary: String::new(),
        attention_count: 0,
        tab_count: 1,
        branch: None,
    }
}

fn layout() -> Layout {
    Layout {
        workspace_id: WS.into(),
        focused_pane_id: PANE.into(),
        root: Node::Pane {
            id: PANE.into(),
            content: PaneContent::Tab { tab: TAB.into() },
            recent_files: vec![],
        },
    }
}

fn samples() -> Vec<(&'static str, Value)> {
    let v = |x: &dyn erased::Ser| x.to_value();
    vec![
        (
            "hello-params",
            v(&HelloParams {
                protocol: 1,
                role: Role::App,
                client: "Mapo/0.1.0".into(),
                credential: Credential {
                    kind: CredentialKind::App,
                    token: "TOKEN".into(),
                },
                attach: None,
            }),
        ),
        (
            "hello-result",
            v(&HelloResult {
                protocol: 1,
                daemon: "0.1.0".into(),
                boot_id: BOOT.into(),
                instance: "dev-mapo-native".into(),
                features: vec!["events".into()],
                caller: Caller {
                    kind: CredentialKind::App,
                    tab_id: None,
                    workspace_id: None,
                },
                attach: None,
            }),
        ),
        (
            "error",
            v(&RpcError::not_found("Tab \"x\" not found")
                .with_hint("mapo tab list")
                .with_details(json!({"names": ["be"]}))),
        ),
        ("tab-summary", v(&tab())),
        ("workspace-summary", v(&workspace())),
        ("layout", v(&layout())),
        (
            "snapshot",
            v(&Snapshot {
                seq: 6,
                boot_id: BOOT.into(),
                active_workspace_id: Some(WS.into()),
                workspaces: vec![workspace()],
                tabs: vec![tab()],
                layouts: BTreeMap::from([(WS.to_owned(), layout())]),
            }),
        ),
        (
            "event-tab-created",
            v(&Event {
                seq: 5,
                boot_id: BOOT.into(),
                at: 1_790_000_000_000,
                kind: "tab.created".into(),
                data: json!(tab()),
            }),
        ),
    ]
}

mod erased {
    pub trait Ser {
        fn to_value(&self) -> serde_json::Value;
    }
    impl<T: serde::Serialize> Ser for T {
        fn to_value(&self) -> serde_json::Value {
            serde_json::to_value(self).unwrap()
        }
    }
}

#[test]
fn fixtures_match() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures");
    let update = std::env::var_os("UPDATE_FIXTURES").is_some();
    let mut stale = vec![];
    for (name, value) in samples() {
        let path = dir.join(format!("{name}.json"));
        let text = serde_json::to_string_pretty(&value).unwrap() + "\n";
        if update {
            std::fs::write(&path, &text).unwrap();
        } else if std::fs::read_to_string(&path).ok().as_deref() != Some(text.as_str()) {
            stale.push(name);
        }
    }
    assert!(
        stale.is_empty(),
        "stale fixtures {stale:?}; run UPDATE_FIXTURES=1 cargo test -p mapo-protocol"
    );
}
