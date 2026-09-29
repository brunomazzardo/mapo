//! `file.open` (PROTOCOL §6.5, REQUIREMENTS §8.10): checks the path before the core touches the
//! layout, so a folder, a missing path, a broken link or an unreadable file never reaches the UI.

use std::path::{Component, Path, PathBuf};

use mapo_protocol::rpc::Request;
use mapo_protocol::types::FileOpen;
use mapo_protocol::{RpcError, methods, parse_params};
use serde_json::Value;

use super::Shared;
use super::conn::Session;

/// `file.open {path, workspace?, beside?}` → `{path, paneId}`.
pub(super) async fn open(
    shared: &Shared,
    session: &Session,
    req: &Request,
) -> Result<Value, RpcError> {
    let mut p: FileOpen = parse_params(&req.params)?;
    let path = normalize(Path::new(&p.path)).ok_or_else(|| {
        RpcError::invalid(format!("path must be absolute, not {:?}", p.path))
            .with_hint("mapo file open resolves relative paths against its own folder")
    })?;
    let checked = path.clone();
    tokio::task::spawn_blocking(move || check(&checked))
        .await
        .map_err(|e| RpcError::internal(format!("file.open: {e}")))??;
    p.path = path.to_string_lossy().into_owned();
    let params = serde_json::to_value(&p).map_err(|e| RpcError::internal(e.to_string()))?;
    shared
        .core
        .call(methods::FILE_OPEN, params, session.caller.clone())
        .await
}

/// An absolute path with `.` and `..` resolved lexically. Symlinks stay as given, so the pane and
/// its identifiers name the path the person opened.
fn normalize(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() {
        return None;
    }
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    Some(out)
}

/// Accepts an existing, readable regular file (following links).
fn check(path: &Path) -> Result<(), RpcError> {
    let shown = path.display();
    let link = std::fs::symlink_metadata(path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => RpcError::not_found(format!("{shown} doesn't exist")),
        std::io::ErrorKind::PermissionDenied => {
            RpcError::forbidden(format!("can't read {shown}: permission denied"))
        }
        _ => RpcError::not_found(format!("can't open {shown}: {e}")),
    })?;
    let meta = if link.file_type().is_symlink() {
        std::fs::metadata(path).map_err(|_| {
            RpcError::not_found(format!(
                "{shown} is a broken link: what it points to doesn't exist"
            ))
        })?
    } else {
        link
    };
    if meta.is_dir() {
        return Err(
            RpcError::conflict(format!("{shown} is a folder; file open takes a file"))
                .with_hint(format!("mapo tab new --cwd {shown}")),
        );
    }
    if !meta.is_file() {
        return Err(RpcError::conflict(format!("{shown} isn't a regular file")));
    }
    std::fs::File::open(path).map_err(|e| match e.kind() {
        std::io::ErrorKind::PermissionDenied => {
            RpcError::forbidden(format!("can't read {shown}: permission denied"))
                .with_hint("check its permissions in Finder, then try again")
        }
        _ => RpcError::forbidden(format!("can't read {shown}: {e}")),
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use mapo_protocol::ErrorKind;

    #[test]
    fn normalize_cases() {
        let cases = [
            ("/a/b/../c", Some("/a/c")),
            ("/a/./b/", Some("/a/b")),
            ("/../a", Some("/a")),
            ("a/b", None),
        ];
        for (input, want) in cases {
            assert_eq!(
                normalize(Path::new(input)),
                want.map(PathBuf::from),
                "{input}"
            );
        }
    }

    #[test]
    fn check_cases() {
        let dir = std::env::temp_dir().join(format!("mapo-file-check-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("a.txt");
        std::fs::write(&file, "a").unwrap();
        let locked = dir.join("locked.txt");
        std::fs::write(&locked, "x").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
        std::os::unix::fs::symlink(dir.join("nope"), dir.join("broken")).unwrap();
        std::os::unix::fs::symlink(&file, dir.join("good")).unwrap();
        let kind = |p: &Path| check(p).err().map(|e| e.kind());
        let cases: Vec<(&str, PathBuf, Option<ErrorKind>)> = vec![
            ("file", file.clone(), None),
            ("link to a file", dir.join("good"), None),
            ("folder", dir.clone(), Some(ErrorKind::Conflict)),
            ("missing", dir.join("missing"), Some(ErrorKind::NotFound)),
            ("broken link", dir.join("broken"), Some(ErrorKind::NotFound)),
            ("unreadable", locked.clone(), Some(ErrorKind::Forbidden)),
        ];
        let got: Vec<_> = cases.iter().map(|(n, p, _)| (*n, kind(p))).collect();
        let want: Vec<_> = cases.iter().map(|(n, _, k)| (*n, *k)).collect();
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o600)).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(got, want);
    }
}
