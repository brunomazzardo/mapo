//! The Changes inspector's data (PROTOCOL §6.5, UX §5.3): `git.status` with line counts, `git.diff` for
//! one file and `git.baseText`, HEAD's version of a file for the editor's gutter.
//!
//! Everything goes through the git CLI with `-c core.fsmonitor=false --no-optional-locks`, so a status
//! never takes the index lock from a git command running in a tab.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use serde::Serialize;

use crate::status::{Repo, RepoStatus};

/// git's empty tree, the base before the first commit.
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
/// Untracked files above this size count as binary instead of being read for a line count.
const MAX_COUNTED_BYTES: u64 = 8 * 1024 * 1024;

/// Why a Changes request failed.
#[derive(Debug, thiserror::Error)]
pub enum ChangesError {
    #[error("{0} isn't inside a git repository")]
    NotARepo(String),
    #[error("{0}")]
    NotFound(String),
    #[error("couldn't run git: {0}")]
    Spawn(#[from] std::io::Error),
    #[error("{0}")]
    Git(String),
}

/// `[changes]` thresholds for the size warning.
#[derive(Debug, Clone, Copy)]
pub struct WarnLimits {
    pub lines: u64,
    pub files: u64,
}

impl Default for WarnLimits {
    fn default() -> Self {
        WarnLimits {
            lines: 1500,
            files: 50,
        }
    }
}

/// One changed file against HEAD.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    /// Relative to the root, `/`-separated.
    pub path: String,
    /// `M`, `A`, `D`, `R`, `?` (untracked) or `U` (conflicted), as in `fs.list`.
    pub status: String,
    pub added: u64,
    pub deleted: u64,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub binary: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Totals {
    pub files: u64,
    pub added: u64,
    pub deleted: u64,
}

/// The `git.status` result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Changes {
    pub root: String,
    /// Nil when HEAD is detached.
    pub branch: Option<String>,
    /// HEAD's short id, for "detached at a7bc6c9"; nil before the first commit.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream: Option<String>,
    pub ahead: u64,
    pub behind: u64,
    pub files: Vec<ChangedFile>,
    pub totals: Totals,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub warn: Option<String>,
}

/// The branch headers of `status --porcelain=v2 --branch`.
#[derive(Debug, Default, PartialEq, Eq)]
struct BranchInfo {
    oid: Option<String>,
    upstream: Option<String>,
    ahead: u64,
    behind: u64,
}

fn parse_branch(out: &[u8]) -> BranchInfo {
    let mut info = BranchInfo::default();
    for record in out.split(|b| *b == 0).map(String::from_utf8_lossy) {
        let Some(rest) = record.strip_prefix("# ") else {
            continue;
        };
        if let Some(oid) = rest.strip_prefix("branch.oid ") {
            info.oid = (oid != "(initial)").then(|| oid.chars().take(7).collect());
        } else if let Some(up) = rest.strip_prefix("branch.upstream ") {
            info.upstream = Some(up.to_owned());
        } else if let Some(ab) = rest.strip_prefix("branch.ab ") {
            let mut parts = ab.split(' ');
            info.ahead = parts
                .next()
                .and_then(|a| a.trim_start_matches('+').parse().ok())
                .unwrap_or(0);
            info.behind = parts
                .next()
                .and_then(|b| b.trim_start_matches('-').parse().ok())
                .unwrap_or(0);
        }
    }
    info
}

/// `diff --numstat -z` → path → (added, deleted), `None` for binary files. A rename's counts go to its
/// new path.
fn parse_numstat(out: &[u8]) -> Vec<(String, Option<(u64, u64)>)> {
    let mut result = Vec::new();
    let mut records = out.split(|b| *b == 0).map(String::from_utf8_lossy);
    while let Some(record) = records.next() {
        let mut fields = record.splitn(3, '\t');
        let (Some(added), Some(deleted), Some(path)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let counts = added.parse().ok().zip(deleted.parse().ok());
        let path = if path.is_empty() {
            // A rename: the old path, then the new one, each its own record.
            records.next();
            match records.next() {
                Some(new) => new.into_owned(),
                None => continue,
            }
        } else {
            path.to_owned()
        };
        result.push((path, counts));
    }
    result
}

fn git(dir: &Path, args: &[&str]) -> Result<Output, ChangesError> {
    Ok(Command::new("git")
        .args(["-c", "core.fsmonitor=false", "--no-optional-locks"])
        .args(args)
        .current_dir(dir)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .output()?)
}

/// Runs git and fails with the first line of its stderr.
fn git_ok(dir: &Path, args: &[&str]) -> Result<Vec<u8>, ChangesError> {
    let out = git(dir, args)?;
    if !out.status.success() {
        return Err(ChangesError::Git(first_line(&out.stderr)));
    }
    Ok(out.stdout)
}

fn first_line(stderr: &[u8]) -> String {
    String::from_utf8_lossy(stderr)
        .lines()
        .next()
        .unwrap_or("git failed")
        .trim_start_matches("fatal: ")
        .to_owned()
}

/// A folder to run git in for `path`: the path itself when it is a folder, else its parent.
fn folder_of(path: &Path) -> PathBuf {
    if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent().unwrap_or(path).to_path_buf()
    }
}

/// `git.status {path}`: every file changed against HEAD in the repository holding `path` (staged,
/// unstaged and untracked together), sorted by path, with line counts and the size warning.
pub fn status(path: &Path, limits: WarnLimits) -> Result<Changes, ChangesError> {
    let repo = Repo::discover(&folder_of(path))
        .ok_or_else(|| ChangesError::NotARepo(path.display().to_string()))?;
    let root = &repo.root;
    let out = git_ok(
        root,
        &[
            "status",
            "--porcelain=v2",
            "-z",
            "--branch",
            "--untracked-files=all",
        ],
    )?;
    let parsed = RepoStatus::parse(&out);
    let info = parse_branch(&out);
    let base = if info.oid.is_some() {
        "HEAD"
    } else {
        EMPTY_TREE
    };
    let numstat = git_ok(root, &["diff", "--numstat", "-z", base, "--"])?;
    let counts: std::collections::HashMap<String, Option<(u64, u64)>> =
        parse_numstat(&numstat).into_iter().collect();

    let mut files: Vec<ChangedFile> = parsed
        .files
        .iter()
        .map(|(rel, letter)| {
            let counts = if *letter == '?' {
                count_lines(&root.join(rel))
            } else {
                counts.get(rel).copied().unwrap_or(Some((0, 0)))
            };
            ChangedFile {
                path: rel.clone(),
                status: letter.to_string(),
                added: counts.map_or(0, |c| c.0),
                deleted: counts.map_or(0, |c| c.1),
                binary: counts.is_none(),
            }
        })
        .collect();
    files.sort_by(|a, b| a.path.cmp(&b.path));
    let totals = Totals {
        files: files.len() as u64,
        added: files.iter().map(|f| f.added).sum(),
        deleted: files.iter().map(|f| f.deleted).sum(),
    };
    let lines = totals.added + totals.deleted;
    let warn = (lines > limits.lines || totals.files > limits.files).then(|| {
        format!(
            "Large change: {} lines in {} files. Consider splitting it.",
            grouped(lines),
            grouped(totals.files)
        )
    });
    Ok(Changes {
        root: root.display().to_string(),
        branch: parsed.branch,
        head: info.oid,
        upstream: info.upstream,
        ahead: info.ahead,
        behind: info.behind,
        files,
        totals,
        warn,
    })
}

/// An untracked file's line count as added lines; `None` when it is binary or too big to read.
fn count_lines(path: &Path) -> Option<(u64, u64)> {
    let meta = std::fs::metadata(path).ok()?;
    if meta.len() > MAX_COUNTED_BYTES {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    if bytes.iter().take(8000).any(|b| *b == 0) {
        return None;
    }
    let mut lines = bytes.iter().filter(|b| **b == b'\n').count() as u64;
    if bytes.last().is_some_and(|b| *b != b'\n') {
        lines += 1;
    }
    Some((lines, 0))
}

/// 1812 → "1,812".
fn grouped(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// A file in `root`: `path` as given when absolute, else joined to the root.
fn resolve(root: &Path, path: &str) -> PathBuf {
    let p = Path::new(path);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        root.join(p)
    }
}

/// `git.diff {root, path}`: the unified diff of one file against HEAD, including staged changes. An
/// untracked file diffs against nothing. Runs in the file's folder, so symlinked paths such as `/var`
/// still resolve inside the repository.
pub fn diff(root: &Path, path: &str) -> Result<String, ChangesError> {
    let file = resolve(root, path);
    let (dir, name) = split(&file)?;
    let has_head = git(&dir, &["rev-parse", "--verify", "-q", "HEAD"])?
        .status
        .success();
    let base = if has_head { "HEAD" } else { EMPTY_TREE };
    let out = git_ok(&dir, &["diff", "--no-color", "-U3", base, "--", &name])?;
    if !out.is_empty() || !file.exists() {
        return Ok(String::from_utf8_lossy(&out).into_owned());
    }
    let tracked = git_ok(&dir, &["ls-files", "--", &name])?;
    if !tracked.is_empty() {
        return Ok(String::new());
    }
    // Untracked: `--no-index` exits 1 when the files differ.
    let out = git(
        &dir,
        &[
            "diff",
            "--no-color",
            "--no-index",
            "-U3",
            "--",
            "/dev/null",
            &name,
        ],
    )?;
    if out.status.code().is_some_and(|c| c > 1) {
        return Err(ChangesError::Git(first_line(&out.stderr)));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The base text for the gutter.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BaseText {
    pub text: String,
    /// HEAD's short id.
    pub rev: String,
}

/// `git.baseText {path}`: the file's text at HEAD. `NotFound` when the file isn't in HEAD (untracked,
/// added, or no commit yet) or isn't in a repository.
pub fn base_text(path: &Path) -> Result<BaseText, ChangesError> {
    let (dir, name) = split(path)?;
    if Repo::discover(&dir).is_none() {
        return Err(ChangesError::NotARepo(path.display().to_string()));
    }
    let rev = git(&dir, &["rev-parse", "--short=7", "--verify", "-q", "HEAD"])?;
    if !rev.status.success() {
        return Err(ChangesError::NotFound(
            "the repository has no commit yet".into(),
        ));
    }
    let out = git(&dir, &["show", &format!("HEAD:./{name}")])?;
    if !out.status.success() {
        return Err(ChangesError::NotFound(format!(
            "{} isn't in HEAD",
            path.display()
        )));
    }
    Ok(BaseText {
        text: String::from_utf8_lossy(&out.stdout).into_owned(),
        rev: String::from_utf8_lossy(&rev.stdout).trim().to_owned(),
    })
}

/// A file's folder and name.
fn split(file: &Path) -> Result<(PathBuf, String), ChangesError> {
    let dir = file.parent().filter(|d| d.is_dir()).ok_or_else(|| {
        ChangesError::NotFound(format!("{}'s folder doesn't exist", file.display()))
    })?;
    let name = file
        .file_name()
        .ok_or_else(|| ChangesError::NotFound(format!("{} isn't a file", file.display())))?;
    Ok((dir.to_path_buf(), name.to_string_lossy().into_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_branch_headers() {
        let out = b"# branch.oid 1234567890\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0";
        assert_eq!(
            parse_branch(out),
            BranchInfo {
                oid: Some("1234567".into()),
                upstream: Some("origin/main".into()),
                ahead: 2,
                behind: 1,
            }
        );
        assert_eq!(parse_branch(b"# branch.oid (initial)\0").oid, None);
    }

    #[test]
    fn parses_numstat() {
        let out = b"3\t1\ta.txt\0-\t-\timg.png\x002\t0\t\0old.txt\0new.txt\0";
        assert_eq!(
            parse_numstat(out),
            vec![
                ("a.txt".into(), Some((3, 1))),
                ("img.png".into(), None),
                ("new.txt".into(), Some((2, 0))),
            ]
        );
    }

    #[test]
    fn groups_thousands() {
        assert_eq!(grouped(7), "7");
        assert_eq!(grouped(1812), "1,812");
        assert_eq!(grouped(1234567), "1,234,567");
    }

    fn run(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    }

    #[test]
    fn status_diff_and_base_text_in_a_repo() {
        let dir = std::env::temp_dir().join(format!("mapo-changes-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).unwrap();
        run(&dir, &["init", "-q"]);
        std::fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
        run(&dir, &["add", "-A"]);
        run(&dir, &["commit", "-qm", "init"]);
        std::fs::write(dir.join("a.txt"), "one\n2\nthree\n").unwrap();
        std::fs::write(dir.join("src/new.rs"), "fn a() {}\n").unwrap();
        run(&dir, &["add", "src/new.rs"]);
        std::fs::write(dir.join("u.txt"), "x\ny").unwrap();

        let c = status(&dir.join("src"), WarnLimits::default()).unwrap();
        let files: Vec<_> = c
            .files
            .iter()
            .map(|f| (f.path.as_str(), f.status.as_str(), f.added, f.deleted))
            .collect();
        assert_eq!(
            files,
            vec![
                ("a.txt", "M", 2, 1),
                ("src/new.rs", "A", 1, 0),
                ("u.txt", "?", 2, 0)
            ]
        );
        assert_eq!(
            c.totals,
            Totals {
                files: 3,
                added: 5,
                deleted: 1
            }
        );
        assert!(c.warn.is_none());
        let warned = status(
            &dir,
            WarnLimits {
                lines: 1,
                files: 50,
            },
        )
        .unwrap();
        assert_eq!(
            warned.warn.as_deref(),
            Some("Large change: 6 lines in 3 files. Consider splitting it.")
        );

        let d = diff(&dir, "a.txt").unwrap();
        assert!(d.contains("-two\n+2\n+three\n"), "{d}");
        let d = diff(&dir, &dir.join("u.txt").display().to_string()).unwrap();
        assert!(d.contains("+x\n+y"), "{d}");
        assert!(diff(&dir, "src/new.rs").unwrap().contains("+fn a() {}"));

        assert_eq!(base_text(&dir.join("a.txt")).unwrap().text, "one\ntwo\n");
        assert!(matches!(
            base_text(&dir.join("u.txt")),
            Err(ChangesError::NotFound(_))
        ));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
