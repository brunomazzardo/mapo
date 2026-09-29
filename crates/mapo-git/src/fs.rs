//! `fs.list`: one folder level with gitignore and exclude rules, and git letters (PROTOCOL §6.5).

use std::cmp::Ordering;
use std::path::Path;

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use serde::Serialize;

use crate::status::{Repo, StatusCache};

/// `[files]` settings (ARCHITECTURE §3.8).
#[derive(Debug, Clone)]
pub struct ListOptions {
    /// Gitignore-style patterns hidden everywhere.
    pub exclude: Vec<String>,
    pub respect_gitignore: bool,
}

impl Default for ListOptions {
    fn default() -> Self {
        ListOptions {
            exclude: vec![".git".into(), ".DS_Store".into()],
            respect_gitignore: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ListState {
    Ready,
    Empty,
    Missing,
    Unreadable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    File,
    Dir,
    Symlink,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Entry {
    pub name: String,
    /// A symlink reports its target's kind; a broken one is `symlink`.
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git: Option<String>,
}

/// The repository a listing belongs to, for the header's branch chip.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RepoInfo {
    pub root: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Listing {
    pub path: String,
    pub state: ListState,
    pub hidden_by_exclude: usize,
    pub entries: Vec<Entry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<RepoInfo>,
}

impl Listing {
    fn state(path: &Path, state: ListState) -> Listing {
        Listing {
            path: path.display().to_string(),
            state,
            hidden_by_exclude: 0,
            entries: vec![],
            repo: None,
        }
    }
}

/// Lists `path` one level deep. Blocks on the file system and, when the status is stale, on git.
pub fn list(path: &Path, options: &ListOptions, cache: &StatusCache) -> Listing {
    match std::fs::metadata(path) {
        Ok(meta) if meta.is_dir() => {}
        Ok(_) => return Listing::state(path, ListState::Missing),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Listing::state(path, ListState::Unreadable);
        }
        Err(_) => return Listing::state(path, ListState::Missing),
    }
    if let Err(e) = std::fs::read_dir(path) {
        let state = if e.kind() == std::io::ErrorKind::NotFound {
            ListState::Missing
        } else {
            ListState::Unreadable
        };
        return Listing::state(path, state);
    }

    let exclude = exclude_matcher(path, &options.exclude);
    let mut hidden_by_exclude = 0;
    let mut entries = vec![];
    let walk = ignore::WalkBuilder::new(path)
        .max_depth(Some(1))
        .hidden(false)
        .ignore(false)
        .parents(true)
        .git_ignore(options.respect_gitignore)
        .git_global(options.respect_gitignore)
        .git_exclude(options.respect_gitignore)
        .follow_links(false)
        .build();
    for item in walk.flatten() {
        if item.depth() == 0 {
            continue;
        }
        let entry_path = item.path();
        let Some(name) = entry_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
        else {
            continue;
        };
        let file_type = item.file_type();
        let kind = match file_type {
            Some(t) if t.is_dir() => Kind::Dir,
            Some(t) if t.is_symlink() => match std::fs::metadata(entry_path) {
                Ok(m) if m.is_dir() => Kind::Dir,
                Ok(_) => Kind::File,
                Err(_) => Kind::Symlink,
            },
            _ => Kind::File,
        };
        if exclude.matched(entry_path, kind == Kind::Dir).is_ignore() {
            hidden_by_exclude += 1;
            continue;
        }
        entries.push(Entry {
            name,
            kind,
            git: None,
        });
    }

    let repo = Repo::discover(path);
    let mut repo_info = None;
    if let Some(repo) = &repo {
        match cache.get(repo) {
            Ok(status) => {
                let prefix = path
                    .strip_prefix(&repo.root)
                    .ok()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default();
                for entry in &mut entries {
                    let rel = if prefix.is_empty() {
                        entry.name.clone()
                    } else {
                        format!("{prefix}/{}", entry.name)
                    };
                    entry.git = status
                        .letter(&rel, entry.kind == Kind::Dir)
                        .map(String::from);
                }
                repo_info = Some(RepoInfo {
                    root: repo.root.display().to_string(),
                    branch: status.branch.clone(),
                });
            }
            Err(e) => {
                tracing::info!(root = %repo.root.display(), error = %e, "no git decorations");
                repo_info = Some(RepoInfo {
                    root: repo.root.display().to_string(),
                    branch: None,
                });
            }
        }
    }

    entries.sort_by(compare);
    Listing {
        path: path.display().to_string(),
        state: if entries.is_empty() {
            ListState::Empty
        } else {
            ListState::Ready
        },
        hidden_by_exclude,
        entries,
        repo: repo_info,
    }
}

fn exclude_matcher(root: &Path, patterns: &[String]) -> Gitignore {
    let mut builder = GitignoreBuilder::new(root);
    for pattern in patterns {
        if let Err(e) = builder.add_line(None, pattern) {
            tracing::warn!(pattern = %pattern, error = %e, "bad [files] exclude pattern");
        }
    }
    builder.build().unwrap_or_else(|_| Gitignore::empty())
}

/// Folders first (R-FS-3), then names in case-insensitive order.
fn compare(a: &Entry, b: &Entry) -> Ordering {
    let rank = |e: &Entry| if e.kind == Kind::Dir { 0 } else { 1 };
    rank(a)
        .cmp(&rank(b))
        .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        .then_with(|| a.name.cmp(&b.name))
}
