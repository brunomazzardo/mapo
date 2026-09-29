//! The process host: runs the core's launch and close commands through mapo-term and keeps the
//! live tab handles for tab.send/read/wait/run and attach.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use mapo_core::actor::HostCmd;
use mapo_term::tab::{HostContext, TabHandle};
use tokio::sync::mpsc;

pub struct Host {
    tabs: Mutex<HashMap<String, TabHandle>>,
}

impl Host {
    pub fn get(&self, id: &str) -> Option<TabHandle> {
        self.tabs.lock().ok()?.get(id).cloned()
    }

    fn insert(&self, id: String, handle: TabHandle) -> Option<TabHandle> {
        self.tabs.lock().ok()?.insert(id, handle)
    }

    fn remove(&self, id: &str) -> Option<TabHandle> {
        self.tabs.lock().ok()?.remove(id)
    }

    fn drain(&self) -> Vec<TabHandle> {
        self.tabs
            .lock()
            .map(|mut m| m.drain().map(|(_, h)| h).collect())
            .unwrap_or_default()
    }

    /// Hangs up every tab (daemon shutdown).
    pub async fn close_all(&self) {
        for h in self.drain() {
            h.close().await;
        }
    }
}

/// Starts the host task. Launches are serialized per tab by the core (one at a time).
pub fn spawn(mut rx: mpsc::UnboundedReceiver<HostCmd>, ctx: Arc<HostContext>) -> Arc<Host> {
    let host = Arc::new(Host {
        tabs: Mutex::new(HashMap::new()),
    });
    let h = host.clone();
    tokio::spawn(async move {
        while let Some(cmd) = rx.recv().await {
            match cmd {
                HostCmd::Launch(spec) => {
                    if let Some(old) = h.remove(&spec.tab_id) {
                        old.close().await;
                    }
                    if let Some(handle) = mapo_term::tab::launch(&spec, &ctx) {
                        tracing::info!(tab = %spec.tab_id, "launched");
                        h.insert(spec.tab_id.clone(), handle);
                    }
                }
                HostCmd::Close { tab_id } => {
                    if let Some(handle) = h.remove(&tab_id) {
                        handle.close().await;
                    }
                }
            }
        }
    });
    host
}
