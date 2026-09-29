//! `fs.list`, `fs.watch` and `fs.unwatch` (PROTOCOL §6.5). `explorer.*` goes to the app like `ui.*`.

use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

use mapo_git::{Change, ListOptions, StatusCache, Watcher};
use mapo_protocol::rpc::{Request, Response};
use mapo_protocol::{RpcError, parse_params};
use serde::Deserialize;
use serde_json::{Value, json};

use super::Shared;

pub const FS_LIST: &str = "fs.list";
pub const FS_WATCH: &str = "fs.watch";
pub const FS_UNWATCH: &str = "fs.unwatch";

/// Git status per repository root, shared by every connection.
static STATUS: LazyLock<StatusCache> = LazyLock::new(StatusCache::default);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PathParams {
    path: String,
}

fn absolute(path: &str) -> Result<PathBuf, RpcError> {
    let p = Path::new(path);
    if !p.is_absolute() {
        return Err(RpcError::invalid(format!(
            "path must be absolute, not {path:?}"
        )));
    }
    Ok(p.to_path_buf())
}

/// `fs.list {path}`.
pub(super) async fn list(shared: &Shared, req: &Request) -> Result<Value, RpcError> {
    let p: PathParams = parse_params(&req.params)?;
    let path = absolute(&p.path)?;
    let options = options(&shared.paths.config);
    let listing = tokio::task::spawn_blocking(move || mapo_git::list(&path, &options, &STATUS))
        .await
        .map_err(|e| RpcError::internal(format!("fs.list: {e}")))?;
    serde_json::to_value(&listing).map_err(|e| RpcError::internal(e.to_string()))
}

/// One connection's watches (fs.watch is connection-scoped); dropping it stops them.
#[derive(Default)]
pub(super) struct Watches(Mutex<Option<Watcher>>);

pub(super) fn is_watch(method: &str) -> bool {
    matches!(method, FS_WATCH | FS_UNWATCH)
}

/// `fs.watch {path}` / `fs.unwatch {path}`, answered inline so the watch set stays per connection.
pub(super) fn watch(shared: &Arc<Shared>, watches: &Watches, req: Request) -> Response {
    match watch_inner(shared, watches, &req) {
        Ok(v) => Response::ok(req.id, v),
        Err(e) => Response::err(Some(req.id), e),
    }
}

fn watch_inner(shared: &Arc<Shared>, watches: &Watches, req: &Request) -> Result<Value, RpcError> {
    let p: PathParams = parse_params(&req.params)?;
    let path = absolute(&p.path)?;
    let mut slot = watches
        .0
        .lock()
        .map_err(|_| RpcError::internal("watch state poisoned"))?;
    if req.method == FS_UNWATCH {
        if let Some(w) = slot.as_mut() {
            w.unwatch(&path);
        }
        return Ok(json!({}));
    }
    if slot.is_none() {
        let core = shared.core.clone();
        let watcher = Watcher::new(move |change| match change {
            Change::Files {
                folder,
                names,
                repo,
            } => {
                if let Some(repo) = repo {
                    STATUS.mark_dirty(&repo);
                }
                core.emit(
                    "fs.changed",
                    json!({ "root": folder.display().to_string(), "paths": names }),
                );
            }
            Change::Git { root } => {
                STATUS.mark_dirty(&root);
                core.emit("git.changed", json!({ "root": root.display().to_string() }));
            }
        })
        .map_err(|e| RpcError::internal(e.to_string()))?;
        *slot = Some(watcher);
    }
    if let Some(w) = slot.as_mut() {
        w.watch(&path).map_err(|e| {
            RpcError::not_found(e.to_string()).with_hint("watch a folder that exists")
        })?;
    }
    Ok(json!({}))
}

/// `[files]` from the instance's `config.toml`: `exclude = [...]` and `respect-gitignore`. A missing file
/// or key keeps the defaults. Only this section's two keys are read, one line each.
fn options(config: &Path) -> ListOptions {
    let mut options = ListOptions::default();
    let Ok(text) = std::fs::read_to_string(config) else {
        return options;
    };
    let mut in_files = false;
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.starts_with('[') {
            in_files = line == "[files]";
            continue;
        }
        if !in_files {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "exclude" => {
                let value = value.trim();
                if let Some(inner) = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')) {
                    options.exclude = inner
                        .split(',')
                        .map(|s| s.trim().trim_matches('"').to_owned())
                        .filter(|s| !s.is_empty())
                        .collect();
                }
            }
            "respect-gitignore" => options.respect_gitignore = value.trim() != "false",
            _ => {}
        }
    }
    options
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_files_section() {
        let dir = std::env::temp_dir().join(format!("mapo-fs-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config.toml");
        std::fs::write(
            &config,
            "[ui]\nexclude = [\"no\"]\n[files]\nexclude = [\".git\", \"node_modules\"] # c\nrespect-gitignore = false\n",
        )
        .unwrap();
        let o = options(&config);
        assert_eq!(o.exclude, vec![".git", "node_modules"]);
        assert!(!o.respect_gitignore);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
