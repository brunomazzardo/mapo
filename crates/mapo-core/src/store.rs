//! Persistence: one thread owns the SQLite connection and applies write batches in a
//! transaction; the actor never waits on disk (PLAN T0.4 steps 1 and 8).

use std::path::Path;
use std::sync::mpsc;

use mapo_protocol::types::{Launch, Layout, TabKind};
use rusqlite::{Connection, OptionalExtension, params};

use crate::model::{Tab, Workspace};
use crate::status::Facts;

const MIGRATIONS: &[&str] = &[include_str!("../migrations/0001_init.sql")];

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("state database: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("state database: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone)]
pub enum Write {
    Workspace(Workspace),
    DeleteWorkspace(String),
    Tab(Tab),
    DeleteTab(String),
    Meta(String, String),
    /// Resolves once everything before it is committed.
    Flush(std::sync::mpsc::Sender<()>),
}

/// State loaded at startup.
#[derive(Debug, Default)]
pub struct Loaded {
    pub workspaces: Vec<Workspace>,
    pub tabs: Vec<Tab>,
    pub active_workspace: Option<String>,
}

pub fn open(path: &Path) -> Result<Connection, StoreError> {
    let conn = Connection::open(path)?;
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(version.max(0) as usize) {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(sql)?;
        tx.pragma_update(None, "user_version", (i + 1) as i64)?;
        tx.commit()?;
    }
    Ok(conn)
}

fn kind_str(k: TabKind) -> &'static str {
    match k {
        TabKind::Shell => "shell",
        TabKind::Agent => "agent",
    }
}

pub fn load(conn: &Connection) -> Result<Loaded, StoreError> {
    let mut out = Loaded::default();
    let mut layouts = std::collections::HashMap::new();
    {
        let mut stmt = conn.prepare("SELECT workspace_id, json FROM layouts")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        for row in rows {
            let (id, json) = row?;
            if let Ok(layout) = serde_json::from_str::<Layout>(&json) {
                layouts.insert(id, layout);
            }
        }
    }
    let mut stmt =
        conn.prepare("SELECT id, name, ord, agent_command FROM workspaces ORDER BY ord")?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, u32>(2)?,
            r.get::<_, Option<String>>(3)?,
        ))
    })?;
    for row in rows {
        let (id, name, order, agent_command) = row?;
        let layout = layouts
            .remove(&id)
            .unwrap_or_else(|| crate::model::single_pane(&id, None));
        out.workspaces.push(Workspace {
            id,
            name,
            order,
            agent_command,
            layout,
            branch: None,
        });
    }
    let mut stmt = conn.prepare(
        "SELECT id, workspace_id, name, labeled, kind, ord, cwd, launch_cwd, launch_command, agent_command
         FROM tabs ORDER BY workspace_id, ord",
    )?;
    let rows = stmt.query_map([], |r| {
        let kind: String = r.get(4)?;
        let kind = if kind == "agent" {
            TabKind::Agent
        } else {
            TabKind::Shell
        };
        Ok(Tab {
            id: r.get(0)?,
            workspace_id: r.get(1)?,
            name: r.get(2)?,
            labeled: r.get(3)?,
            live_title: String::new(),
            kind,
            order: r.get(5)?,
            cwd: r.get(6)?,
            launch: Launch {
                cwd: r.get(7)?,
                command: r.get(8)?,
                agent_command: r.get(9)?,
            },
            facts: Facts {
                kind: Some(kind),
                ..Default::default()
            },
            last_exit: None,
            launch_error: None,
            program: None,
            command_started: None,
        })
    })?;
    for row in rows {
        out.tabs.push(row?);
    }
    out.active_workspace = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'active_workspace'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(out)
}

fn apply(conn: &Connection, w: &Write) -> Result<(), StoreError> {
    match w {
        Write::Workspace(ws) => {
            conn.execute(
                "INSERT INTO workspaces (id, name, ord, agent_command) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(id) DO UPDATE SET name = ?2, ord = ?3, agent_command = ?4",
                params![ws.id, ws.name, ws.order, ws.agent_command],
            )?;
            conn.execute(
                "INSERT INTO layouts (workspace_id, json) VALUES (?1, ?2)
                 ON CONFLICT(workspace_id) DO UPDATE SET json = ?2",
                params![ws.id, serde_json::to_string(&ws.layout)?],
            )?;
        }
        Write::DeleteWorkspace(id) => {
            conn.execute("DELETE FROM tabs WHERE workspace_id = ?1", params![id])?;
            conn.execute("DELETE FROM layouts WHERE workspace_id = ?1", params![id])?;
            conn.execute("DELETE FROM workspaces WHERE id = ?1", params![id])?;
        }
        Write::Tab(t) => {
            conn.execute(
                "INSERT INTO tabs (id, workspace_id, name, labeled, kind, ord, cwd, launch_cwd, launch_command, agent_command)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT(id) DO UPDATE SET workspace_id = ?2, name = ?3, labeled = ?4, kind = ?5, ord = ?6,
                   cwd = ?7, launch_cwd = ?8, launch_command = ?9, agent_command = ?10",
                params![
                    t.id,
                    t.workspace_id,
                    t.name,
                    t.labeled,
                    kind_str(t.kind),
                    t.order,
                    t.cwd,
                    t.launch.cwd,
                    t.launch.command,
                    t.launch.agent_command
                ],
            )?;
        }
        Write::DeleteTab(id) => {
            conn.execute("DELETE FROM tabs WHERE id = ?1", params![id])?;
        }
        Write::Meta(k, v) => {
            conn.execute(
                "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2",
                params![k, v],
            )?;
        }
        Write::Flush(_) => {}
    }
    Ok(())
}

/// Runs the writer thread; returns its sender. Batches arrive as `Vec<Write>`.
pub fn spawn_writer(mut conn: Connection) -> mpsc::Sender<Vec<Write>> {
    let (tx, rx) = mpsc::channel::<Vec<Write>>();
    let _ = std::thread::Builder::new()
        .name("mapo-sqlite".into())
        .spawn(move || {
            while let Ok(mut batch) = rx.recv() {
                while let Ok(more) = rx.try_recv() {
                    batch.extend(more);
                }
                let result = (|| -> Result<(), StoreError> {
                    let tx = conn.transaction()?;
                    for w in &batch {
                        apply(&tx, w)?;
                    }
                    tx.commit()?;
                    Ok(())
                })();
                if let Err(e) = result {
                    tracing::error!(error = %e, "state write failed");
                }
                for w in batch {
                    if let Write::Flush(done) = w {
                        let _ = done.send(());
                    }
                }
            }
        });
    tx
}
