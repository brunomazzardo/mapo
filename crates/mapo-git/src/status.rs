//! Repository discovery and the git status cache (ARCHITECTURE §3.7).
//!
//! One cache slot per repository root holds the parsed output of
//! `git -c core.fsmonitor=false --no-optional-locks status --porcelain=v2 -z --branch --untracked-files=all`.
//! Watchers mark a slot dirty; the next listing reruns git. A clean slot still expires after
//! [`StatusCache::MAX_AGE`], because watches only cover the folders the inspector shows.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A repository found by walking up from a path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Repo {
    /// The working tree root: the folder that holds `.git`.
    pub root: PathBuf,
    /// The git dir: `.git`, or where a worktree's `.git` file points.
    pub git_dir: PathBuf,
    /// The common dir that holds `refs/` (differs from `git_dir` in a linked worktree).
    pub common_dir: PathBuf,
}

impl Repo {
    /// The innermost repository containing `path`, if any.
    pub fn discover(path: &Path) -> Option<Repo> {
        let mut dir = Some(path);
        while let Some(d) = dir {
            let dot_git = d.join(".git");
            if let Ok(meta) = std::fs::metadata(&dot_git) {
                let git_dir = if meta.is_dir() {
                    dot_git
                } else {
                    let text = std::fs::read_to_string(&dot_git).ok()?;
                    let target = text.trim().strip_prefix("gitdir:")?.trim();
                    let target = Path::new(target);
                    if target.is_absolute() {
                        target.to_path_buf()
                    } else {
                        d.join(target)
                    }
                };
                let common_dir = std::fs::read_to_string(git_dir.join("commondir"))
                    .ok()
                    .map(|c| {
                        let c = Path::new(c.trim());
                        if c.is_absolute() {
                            c.to_path_buf()
                        } else {
                            git_dir.join(c)
                        }
                    })
                    .unwrap_or_else(|| git_dir.clone());
                return Some(Repo {
                    root: d.to_path_buf(),
                    git_dir,
                    common_dir,
                });
            }
            dir = d.parent();
        }
        None
    }
}

/// Why git status could not be read.
#[derive(Debug, thiserror::Error)]
pub enum StatusError {
    #[error("couldn't run git: {0}")]
    Spawn(#[from] std::io::Error),
    #[error("git status failed: {0}")]
    Failed(String),
}

/// One repository's status: the letter per changed path and the worst letter per folder.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct RepoStatus {
    /// `branch.head`, or `None` when detached.
    pub branch: Option<String>,
    /// Path relative to the root (`/`-separated) → `M`, `A`, `D`, `R`, `?` or `U`.
    pub files: HashMap<String, char>,
    /// Folder relative to the root → the worst letter below it (UX §5.2: C, then M, then A or U).
    pub dirs: HashMap<String, char>,
}

impl RepoStatus {
    /// Parses `status --porcelain=v2 -z --branch` output.
    pub fn parse(out: &[u8]) -> RepoStatus {
        let mut status = RepoStatus::default();
        let mut records = out.split(|b| *b == 0).map(String::from_utf8_lossy);
        while let Some(record) = records.next() {
            let mut fields = record.splitn(2, ' ');
            let (Some(kind), Some(rest)) = (fields.next(), fields.next()) else {
                continue;
            };
            match kind {
                "#" => {
                    if let Some(head) = rest.strip_prefix("branch.head ") {
                        status.branch = (head != "(detached)").then(|| head.to_owned());
                    }
                }
                "1" => {
                    // XY sub mH mI mW hH hI path
                    let parts: Vec<&str> = rest.splitn(8, ' ').collect();
                    if let (Some(xy), Some(path)) = (parts.first(), parts.get(7)) {
                        status.add(path, letter(xy));
                    }
                }
                "2" => {
                    // XY sub mH mI mW hH hI Xscore path, then the original path as its own record.
                    let parts: Vec<&str> = rest.splitn(9, ' ').collect();
                    if let (Some(xy), Some(path)) = (parts.first(), parts.get(8)) {
                        status.add(path, letter(xy));
                    }
                    records.next();
                }
                "u" => {
                    // XY sub m1 m2 m3 mW h1 h2 h3 path
                    if let Some(path) = rest.splitn(10, ' ').nth(9) {
                        status.add(path, 'U');
                    }
                }
                "?" => status.add(rest, '?'),
                _ => {}
            }
        }
        status
    }

    fn add(&mut self, path: &str, letter: char) {
        let path = path.trim_end_matches('/');
        self.files.insert(path.to_owned(), letter);
        let mut dir = path;
        while let Some((parent, _)) = dir.rsplit_once('/') {
            let slot = self.dirs.entry(parent.to_owned()).or_insert(letter);
            if rank(letter) > rank(*slot) {
                *slot = letter;
            }
            dir = parent;
        }
    }

    /// The letter for an entry at `rel` (relative to the root); folders get their worst child.
    pub fn letter(&self, rel: &str, is_dir: bool) -> Option<char> {
        if is_dir {
            self.dirs.get(rel).or_else(|| self.files.get(rel)).copied()
        } else {
            self.files.get(rel).copied()
        }
    }
}

/// The ordinary-entry letter for an `XY` pair.
fn letter(xy: &str) -> char {
    let mut chars = xy.chars();
    let (x, y) = (chars.next().unwrap_or('.'), chars.next().unwrap_or('.'));
    match (x, y) {
        ('A', _) => 'A',
        ('R' | 'C', _) => 'R',
        ('D', _) | (_, 'D') => 'D',
        _ => 'M',
    }
}

/// Worst first: conflicts, then modifications and deletions, then additions and untracked files.
fn rank(letter: char) -> u8 {
    match letter {
        'U' => 4,
        'M' | 'D' => 3,
        'A' | 'R' => 2,
        _ => 1,
    }
}

struct Slot {
    status: Arc<RepoStatus>,
    at: Instant,
    dirty: bool,
}

/// Status per repository root, shared by every connection.
#[derive(Default)]
pub struct StatusCache {
    slots: Mutex<HashMap<PathBuf, Slot>>,
}

impl StatusCache {
    /// A clean slot is reused for this long.
    pub const MAX_AGE: Duration = Duration::from_secs(5);

    /// The repository's status, from the cache or a fresh `git status`. Blocks while git runs.
    pub fn get(&self, repo: &Repo) -> Result<Arc<RepoStatus>, StatusError> {
        if let Ok(slots) = self.slots.lock()
            && let Some(slot) = slots.get(&key(&repo.root))
            && !slot.dirty
            && slot.at.elapsed() < Self::MAX_AGE
        {
            return Ok(slot.status.clone());
        }
        let started = Instant::now();
        let status = Arc::new(run_status(&repo.root)?);
        tracing::debug!(root = %repo.root.display(), ms = started.elapsed().as_millis() as u64, files = status.files.len(), "git status");
        if let Ok(mut slots) = self.slots.lock() {
            slots.insert(
                key(&repo.root),
                Slot {
                    status: status.clone(),
                    at: started,
                    dirty: false,
                },
            );
        }
        Ok(status)
    }

    /// The next `get` for this root reruns git.
    pub fn mark_dirty(&self, root: &Path) {
        if let Ok(mut slots) = self.slots.lock()
            && let Some(slot) = slots.get_mut(&key(root))
        {
            slot.dirty = true;
        }
    }
}

/// Slots are keyed by the real path, so `/var/…` and `/private/var/…` share one.
fn key(root: &Path) -> PathBuf {
    std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf())
}

fn run_status(root: &Path) -> Result<RepoStatus, StatusError> {
    let out = Command::new("git")
        .args([
            "-c",
            "core.fsmonitor=false",
            "--no-optional-locks",
            "status",
            "--porcelain=v2",
            "-z",
            "--branch",
            "--untracked-files=all",
        ])
        .current_dir(root)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(std::process::Stdio::null())
        .output()?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(StatusError::Failed(
            stderr.lines().next().unwrap_or("unknown error").to_owned(),
        ));
    }
    Ok(RepoStatus::parse(&out.stdout))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_porcelain_v2() {
        let out = b"# branch.oid 1234\0# branch.head main\0\
1 .M N... 100644 100644 100644 aaa bbb src/a.txt\0\
1 A. N... 000000 100644 100644 000 bbb src/deep/new.rs\0\
2 R. N... 100644 100644 100644 aaa bbb R100 moved name.txt\0old name.txt\0\
u UU N... 100644 100644 100644 100644 a b c conflict.txt\0\
? untracked/x.txt\0";
        let s = RepoStatus::parse(out);
        assert_eq!(s.branch.as_deref(), Some("main"));
        let mut files: Vec<_> = s.files.iter().map(|(k, v)| (k.as_str(), *v)).collect();
        files.sort();
        assert_eq!(
            files,
            vec![
                ("conflict.txt", 'U'),
                ("moved name.txt", 'R'),
                ("src/a.txt", 'M'),
                ("src/deep/new.rs", 'A'),
                ("untracked/x.txt", '?'),
            ]
        );
        assert_eq!(s.letter("src", true), Some('M'));
        assert_eq!(s.letter("src/deep", true), Some('A'));
        assert_eq!(s.letter("untracked", true), Some('?'));
        assert_eq!(s.letter("src/a.txt", false), Some('M'));
    }

    #[test]
    fn detached_head_has_no_branch() {
        let s = RepoStatus::parse(b"# branch.oid abc\0# branch.head (detached)\0");
        assert_eq!(s.branch, None);
    }
}
