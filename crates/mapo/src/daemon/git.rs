//! `git.status`, `git.diff` and `git.baseText` (PROTOCOL §6.5): the Changes inspector, the diff pane
//! and the editor's gutter. git runs on a blocking thread; nothing is cached, so a commit shows at once.

use std::path::{Path, PathBuf};

use mapo_git::changes::{self, ChangesError, WarnLimits};
use mapo_protocol::rpc::Request;
use mapo_protocol::{RpcError, methods, parse_params};
use serde::Deserialize;
use serde_json::{Value, json};

use super::Shared;

pub(super) fn handles(method: &str) -> bool {
    matches!(
        method,
        methods::GIT_STATUS | methods::GIT_DIFF | methods::GIT_BASE_TEXT
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StatusParams {
    path: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DiffParams {
    root: String,
    path: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BaseParams {
    path: String,
    /// Accepted for symmetry with `git.diff`; a relative `path` resolves against it.
    #[serde(default)]
    root: Option<String>,
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

fn rpc_error(e: ChangesError) -> RpcError {
    match e {
        ChangesError::NotARepo(_) | ChangesError::NotFound(_) => RpcError::not_found(e.to_string()),
        ChangesError::Spawn(_) => RpcError::unavailable(e.to_string()),
        ChangesError::Git(_) => RpcError::internal(e.to_string()),
    }
}

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, ChangesError> + Send + 'static,
) -> Result<T, RpcError> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| RpcError::internal(format!("git: {e}")))?
        .map_err(rpc_error)
}

pub(super) async fn dispatch(shared: &Shared, req: &Request) -> Result<Value, RpcError> {
    match req.method.as_str() {
        methods::GIT_STATUS => {
            let p: StatusParams = parse_params(&req.params)?;
            let path = absolute(&p.path)?;
            let limits = limits(&shared.paths.config);
            let result = blocking(move || changes::status(&path, limits)).await?;
            serde_json::to_value(&result).map_err(|e| RpcError::internal(e.to_string()))
        }
        methods::GIT_DIFF => {
            let p: DiffParams = parse_params(&req.params)?;
            let root = absolute(&p.root)?;
            let text = blocking(move || changes::diff(&root, &p.path)).await?;
            Ok(json!({ "text": text }))
        }
        methods::GIT_BASE_TEXT => {
            let p: BaseParams = parse_params(&req.params)?;
            let path = match (&p.root, Path::new(&p.path).is_absolute()) {
                (Some(root), false) => absolute(root)?.join(&p.path),
                _ => absolute(&p.path)?,
            };
            let base = blocking(move || changes::base_text(&path)).await?;
            serde_json::to_value(&base).map_err(|e| RpcError::internal(e.to_string()))
        }
        other => Err(RpcError::invalid(format!("unknown method {other}"))),
    }
}

/// `[changes] warn-lines` and `warn-files` from the instance's `config.toml`; missing keys keep 1,500
/// and 50.
fn limits(config: &Path) -> WarnLimits {
    let mut limits = WarnLimits::default();
    let Ok(text) = std::fs::read_to_string(config) else {
        return limits;
    };
    let mut in_changes = false;
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.starts_with('[') {
            in_changes = line == "[changes]";
            continue;
        }
        let Some((key, value)) = line.split_once('=').filter(|_| in_changes) else {
            continue;
        };
        let value = value.trim().replace('_', "").parse().ok();
        match (key.trim(), value) {
            ("warn-lines", Some(v)) => limits.lines = v,
            ("warn-files", Some(v)) => limits.files = v,
            _ => {}
        }
    }
    limits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_changes_section() {
        let dir = std::env::temp_dir().join(format!("mapo-git-limits-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config.toml");
        std::fs::write(
            &config,
            "[files]\nwarn-lines = 1\n[changes]\nwarn-lines = 2_000 # c\nwarn-files = 20\n",
        )
        .unwrap();
        let l = limits(&config);
        assert_eq!((l.lines, l.files), (2000, 20));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
