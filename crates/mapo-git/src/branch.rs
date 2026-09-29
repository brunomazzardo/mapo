//! Repository discovery and the current branch, read straight from `.git/HEAD` (PLAN T1.1).
//! Linked worktrees have a `.git` file with `gitdir: <path>`; that directory holds their HEAD.

use std::path::{Path, PathBuf};

/// The repository root containing `dir`: the nearest ancestor with a `.git` entry.
pub fn repo_root(dir: &Path) -> Option<PathBuf> {
    dir.ancestors()
        .find(|d| d.join(".git").exists())
        .map(Path::to_path_buf)
}

/// The git directory of a repository root, following a `gitdir:` file.
pub fn git_dir(root: &Path) -> Option<PathBuf> {
    let dot_git = root.join(".git");
    if dot_git.is_dir() {
        return Some(dot_git);
    }
    let text = std::fs::read_to_string(&dot_git).ok()?;
    let target = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
    let path = Path::new(target);
    Some(if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    })
}

/// Parses HEAD: `ref: refs/heads/<name>` gives the branch; a bare hash gives its first 7 chars.
pub fn parse_head(head: &str) -> Option<String> {
    let head = head.trim();
    if let Some(r) = head.strip_prefix("ref:") {
        let r = r.trim();
        return Some(r.strip_prefix("refs/heads/").unwrap_or(r).to_owned());
    }
    (head.len() >= 7 && head.chars().all(|c| c.is_ascii_hexdigit())).then(|| head[..7].to_owned())
}

/// The branch (or short commit when detached) of the repository containing `dir`.
pub fn branch(dir: &Path) -> Option<String> {
    let root = repo_root(dir)?;
    let head = std::fs::read_to_string(git_dir(&root)?.join("HEAD")).ok()?;
    parse_head(&head)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heads() {
        let got: Vec<Option<String>> = [
            "ref: refs/heads/main\n",
            "ref: refs/heads/feat/x",
            "3c47ca159368eb4a860ffe5333abdf4a85b2767b\n",
            "ref: refs/remotes/origin/HEAD",
            "garbage",
        ]
        .iter()
        .map(|h| parse_head(h))
        .collect();
        assert_eq!(
            got,
            vec![
                Some("main".into()),
                Some("feat/x".into()),
                Some("3c47ca1".into()),
                Some("refs/remotes/origin/HEAD".into()),
                None
            ]
        );
    }

    #[test]
    fn worktree_gitdir_file() {
        let dir = std::env::temp_dir().join(format!("mapo-branch-test-{}", std::process::id()));
        let main_git = dir.join("main/.git/worktrees/wt");
        std::fs::create_dir_all(&main_git).unwrap();
        std::fs::write(main_git.join("HEAD"), "ref: refs/heads/native\n").unwrap();
        let wt = dir.join("wt/src/deep");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(
            dir.join("wt/.git"),
            format!("gitdir: {}\n", main_git.display()),
        )
        .unwrap();
        assert_eq!(branch(&wt), Some("native".into()));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
