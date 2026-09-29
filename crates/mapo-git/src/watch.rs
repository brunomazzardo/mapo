//! `fs.watch`: FSEvents through notify, debounced (PROTOCOL §6.5, ARCHITECTURE §3.7).
//!
//! Each watched folder is watched non-recursively, so a busy build tree below a collapsed folder costs
//! nothing: the inspector watches its root and every folder it has expanded. The git dir of each
//! repository involved is watched recursively, and only changes to `HEAD`, `index`, `packed-refs` and
//! `refs/` count as git changes.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{DebounceEventResult, Debouncer, NoCache, new_debouncer_opt};

use crate::status::Repo;

/// The debounce window (R-FS-3).
pub const DEBOUNCE: Duration = Duration::from_millis(150);

/// What a debounced batch changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    /// Entries of a watched folder changed. `folder` is spelled as the caller watched it; `names` are
    /// entry names in it, empty when the folder itself was created, removed or renamed.
    Files {
        folder: PathBuf,
        names: Vec<String>,
        repo: Option<PathBuf>,
    },
    /// `HEAD`, the index or a ref of the repository at `root` changed.
    Git { root: PathBuf },
}

#[derive(Debug, thiserror::Error)]
pub enum WatchError {
    #[error("can't watch {path}: {source}")]
    Watch {
        path: String,
        #[source]
        source: notify::Error,
    },
}

struct Folder {
    /// The spelling the caller used.
    given: PathBuf,
    count: usize,
    repo: Option<Repo>,
}

#[derive(Default)]
struct State {
    /// Canonical folder path → folder.
    folders: HashMap<PathBuf, Folder>,
    /// Canonical git or common dir → (working tree root, watch count).
    git_dirs: HashMap<PathBuf, (PathBuf, usize)>,
}

/// One connection's watches; dropping it stops them all.
pub struct Watcher {
    debouncer: Debouncer<RecommendedWatcher, NoCache>,
    state: Arc<Mutex<State>>,
}

impl Watcher {
    /// Starts a watcher that reports each debounced batch to `sink`, on notify's thread.
    pub fn new(sink: impl Fn(Change) + Send + 'static) -> Result<Watcher, WatchError> {
        let state = Arc::new(Mutex::new(State::default()));
        let handler_state = state.clone();
        let debouncer = new_debouncer_opt::<_, RecommendedWatcher, NoCache>(
            DEBOUNCE,
            None,
            move |result: DebounceEventResult| {
                let Ok(events) = result else { return };
                let Ok(state) = handler_state.lock() else {
                    return;
                };
                let paths = events.iter().flat_map(|e| e.paths.iter());
                for change in classify(&state, paths) {
                    sink(change);
                }
            },
            NoCache,
            notify::Config::default(),
        )
        .map_err(|source| WatchError::Watch {
            path: String::new(),
            source,
        })?;
        Ok(Watcher { debouncer, state })
    }

    /// Watches `folder` (counted: a second watch needs a second unwatch).
    pub fn watch(&mut self, folder: &Path) -> Result<(), WatchError> {
        let canonical = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf());
        let Ok(mut state) = self.state.lock() else {
            return Ok(());
        };
        if let Some(existing) = state.folders.get_mut(&canonical) {
            existing.count += 1;
            return Ok(());
        }
        self.debouncer
            .watch(&canonical, RecursiveMode::NonRecursive)
            .map_err(|source| WatchError::Watch {
                path: folder.display().to_string(),
                source,
            })?;
        // The caller's spelling, so `git.changed {root}` matches the root `fs.list` reported.
        let repo = Repo::discover(folder);
        if let Some(repo) = &repo {
            let mut dirs = vec![repo.git_dir.clone()];
            if repo.common_dir != repo.git_dir {
                dirs.push(repo.common_dir.clone());
            }
            for dir in dirs {
                let dir = std::fs::canonicalize(&dir).unwrap_or(dir);
                if let Some((_, count)) = state.git_dirs.get_mut(&dir) {
                    *count += 1;
                    continue;
                }
                match self.debouncer.watch(&dir, RecursiveMode::Recursive) {
                    Ok(()) => {
                        state.git_dirs.insert(dir, (repo.root.clone(), 1));
                    }
                    Err(e) => {
                        tracing::info!(dir = %dir.display(), error = %e, "git dir not watched");
                    }
                }
            }
        }
        state.folders.insert(
            canonical,
            Folder {
                given: folder.to_path_buf(),
                count: 1,
                repo,
            },
        );
        Ok(())
    }

    /// Drops one watch of `folder`; the last one stops watching it. Unknown folders are ignored.
    pub fn unwatch(&mut self, folder: &Path) {
        let canonical = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf());
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        let key = if state.folders.contains_key(&canonical) {
            canonical
        } else if let Some(k) = state
            .folders
            .iter()
            .find(|(_, f)| f.given == folder)
            .map(|(k, _)| k.clone())
        {
            k
        } else {
            return;
        };
        let Some(entry) = state.folders.get_mut(&key) else {
            return;
        };
        entry.count -= 1;
        if entry.count > 0 {
            return;
        }
        let repo = state.folders.remove(&key).and_then(|f| f.repo);
        let _ = self.debouncer.unwatch(&key);
        if let Some(repo) = repo {
            let mut dirs = vec![repo.git_dir.clone()];
            if repo.common_dir != repo.git_dir {
                dirs.push(repo.common_dir.clone());
            }
            for dir in dirs {
                let dir = std::fs::canonicalize(&dir).unwrap_or(dir);
                if let Some((_, count)) = state.git_dirs.get_mut(&dir) {
                    *count -= 1;
                    if *count == 0 {
                        state.git_dirs.remove(&dir);
                        let _ = self.debouncer.unwatch(&dir);
                    }
                }
            }
        }
    }

    /// How many folders are watched.
    pub fn len(&self) -> usize {
        self.state.lock().map(|s| s.folders.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Sorts changed paths into folder and git changes, one change per folder or repository.
fn classify<'a>(state: &State, paths: impl Iterator<Item = &'a PathBuf>) -> Vec<Change> {
    let mut files: Vec<(PathBuf, Vec<String>, Option<PathBuf>)> = vec![];
    let mut git: Vec<PathBuf> = vec![];
    for path in paths {
        if let Some(root) = git_change(state, path) {
            if !git.contains(&root) {
                git.push(root);
            }
            continue;
        }
        // The watched folder itself (created, removed, renamed), or an entry directly in one.
        let (folder, name) = if let Some(f) = state.folders.get(path.as_path()) {
            (f, None)
        } else if let Some(f) = path.parent().and_then(|p| state.folders.get(p)) {
            (
                f,
                path.file_name().map(|n| n.to_string_lossy().into_owned()),
            )
        } else {
            continue;
        };
        let slot = match files.iter_mut().position(|(g, _, _)| *g == folder.given) {
            Some(i) => &mut files[i],
            None => {
                files.push((
                    folder.given.clone(),
                    vec![],
                    folder.repo.as_ref().map(|r| r.root.clone()),
                ));
                let last = files.len() - 1;
                &mut files[last]
            }
        };
        if let Some(name) = name
            && !slot.1.contains(&name)
        {
            slot.1.push(name);
        }
    }
    files
        .into_iter()
        .map(|(folder, names, repo)| Change::Files {
            folder,
            names,
            repo,
        })
        .chain(git.into_iter().map(|root| Change::Git { root }))
        .collect()
}

/// The working tree root when `path` is `HEAD`, `index`, `packed-refs` or under `refs/` of a watched git dir.
fn git_change(state: &State, path: &Path) -> Option<PathBuf> {
    state.git_dirs.iter().find_map(|(dir, (root, _))| {
        let rel = path.strip_prefix(dir).ok()?;
        let first = rel.components().next()?.as_os_str().to_str()?;
        matches!(first, "HEAD" | "index" | "packed-refs" | "refs").then(|| root.clone())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_folder_and_git_changes() {
        let mut state = State::default();
        state.folders.insert(
            PathBuf::from("/private/r"),
            Folder {
                given: PathBuf::from("/r"),
                count: 1,
                repo: None,
            },
        );
        state
            .git_dirs
            .insert(PathBuf::from("/private/r/.git"), (PathBuf::from("/r"), 1));
        let paths = [
            PathBuf::from("/private/r/a.txt"),
            PathBuf::from("/private/r/a.txt"),
            PathBuf::from("/private/r/sub/deep.txt"),
            PathBuf::from("/private/r/.git/index"),
            PathBuf::from("/private/r/.git/objects/ab/cdef"),
            PathBuf::from("/private/r/.git/refs/heads/main"),
        ];
        let changes = classify(&state, paths.iter());
        assert_eq!(
            changes,
            vec![
                Change::Files {
                    folder: PathBuf::from("/r"),
                    names: vec!["a.txt".into()],
                    repo: None
                },
                Change::Git {
                    root: PathBuf::from("/r")
                },
            ]
        );
    }
}
