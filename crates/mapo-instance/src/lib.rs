//! Instance names, paths, runtime dir, locks and tokens (ENGINEERING §2).
//!
//! Every Mapo process resolves its instance here, so the CLI, the daemon, `mapo attach`
//! and the app (through `mapo instance show --json`) always agree.

mod paths;
mod pidfile;
mod process;
mod secret;

use std::path::{Path, PathBuf};

pub use paths::{Paths, data_root, ensure_private_dir, runtime_dir};
pub use pidfile::{PidFile, read_pid_file, remove_pid_file, write_pid_file};
pub use process::{process_alive, process_args, process_exe, process_matches};
pub use secret::{Secret, read_token, write_token};

/// Longest instance name (the regex allows one leading character plus 31).
pub const MAX_NAME_LEN: usize = 32;

/// The pattern instance names must match, quoted in error messages.
pub const NAME_PATTERN: &str = "[a-z0-9][a-z0-9-]{0,31}";

/// The reserved name of the installed app's instance.
pub const MAIN: &str = "main";

#[derive(Debug, thiserror::Error)]
pub enum InstanceError {
    #[error("invalid instance name {name:?}: names match {NAME_PATTERN}")]
    InvalidName { name: String },
    #[error(
        "the worktree folder {folder:?} doesn't give a valid instance name ({NAME_PATTERN}); rename the folder or pass --instance"
    )]
    InvalidWorktreeName { folder: String },
    #[error(
        "refusing instance main: this binary runs from the git worktree {}; dev builds never serve, stop or clean main",
        worktree.display()
    )]
    MainRefused { worktree: PathBuf },
    #[error("{}: {message}", path.display())]
    Unsafe { path: PathBuf, message: String },
    #[error("{context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },
}

impl InstanceError {
    pub fn io(context: impl Into<String>, source: std::io::Error) -> Self {
        Self::Io {
            context: context.into(),
            source,
        }
    }

    /// Whether the error is the caller's fault (exit 2, `invalid_argument`).
    pub fn is_invalid_argument(&self) -> bool {
        matches!(
            self,
            Self::InvalidName { .. } | Self::InvalidWorktreeName { .. }
        )
    }
}

/// Where the instance name came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    Flag,
    Env,
    Worktree,
    Default,
}

/// A resolved instance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Instance {
    pub name: String,
    pub source: Source,
    /// The git worktree that contains this process's executable, if any.
    pub worktree: Option<PathBuf>,
}

impl Instance {
    /// Fails for `main` when the executable lives inside a git worktree.
    pub fn refuse_main_from_worktree(&self) -> Result<(), InstanceError> {
        match (&self.worktree, self.name == MAIN) {
            (Some(worktree), true) => Err(InstanceError::MainRefused {
                worktree: worktree.clone(),
            }),
            _ => Ok(()),
        }
    }

    pub fn paths(&self) -> Result<Paths, InstanceError> {
        Paths::for_instance(&self.name)
    }
}

/// Checks a name against [`NAME_PATTERN`].
pub fn is_valid_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    let Some(first) = bytes.first() else {
        return false;
    };
    bytes.len() <= MAX_NAME_LEN
        && (first.is_ascii_lowercase() || first.is_ascii_digit())
        && bytes
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

/// Resolves the instance: `--instance`, then `MAPO_INSTANCE`, then the worktree
/// default derived from the executable's real path, then `main` (ENGINEERING §2.1).
pub fn resolve(
    flag: Option<&str>,
    env: Option<&str>,
    exe: &Path,
) -> Result<Instance, InstanceError> {
    let worktree = find_worktree(exe);
    let (name, source) = if let Some(name) = flag.filter(|s| !s.is_empty()) {
        (name.to_owned(), Source::Flag)
    } else if let Some(name) = env.filter(|s| !s.is_empty()) {
        (name.to_owned(), Source::Env)
    } else if let Some(root) = &worktree {
        let folder = root
            .file_name()
            .map(|f| f.to_string_lossy().into_owned())
            .unwrap_or_default();
        let name = format!("dev-{folder}");
        if !is_valid_name(&name) {
            return Err(InstanceError::InvalidWorktreeName { folder });
        }
        (name, Source::Worktree)
    } else {
        (MAIN.to_owned(), Source::Default)
    };
    if !is_valid_name(&name) {
        return Err(InstanceError::InvalidName { name });
    }
    Ok(Instance {
        name,
        source,
        worktree,
    })
}

/// Resolves for the current process, reading `MAPO_INSTANCE` and `current_exe`.
pub fn resolve_current(flag: Option<&str>) -> Result<Instance, InstanceError> {
    let exe = std::env::current_exe().map_err(|e| InstanceError::io("current_exe", e))?;
    let env = std::env::var("MAPO_INSTANCE").ok();
    resolve(flag, env.as_deref(), &exe)
}

/// Walks up from the executable's real path to the first directory holding `.git`.
pub fn find_worktree(exe: &Path) -> Option<PathBuf> {
    let real = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
    real.ancestors()
        .skip(1)
        .find(|dir| dir.join(".git").exists())
        .map(Path::to_path_buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        let long_ok = "a".repeat(32);
        let long_bad = "a".repeat(33);
        let cases = [
            ("dev-mapo-native", true),
            ("main", true),
            ("0abc", true),
            ("drive-m0-skeleton-231500", true),
            ("", false),
            ("-dev", false),
            ("Bad_Name", false),
            ("dev_mapo", false),
            ("dev mapo", false),
            (long_ok.as_str(), true),
            (long_bad.as_str(), false),
        ];
        let got: Vec<(&str, bool)> = cases.iter().map(|(n, _)| (*n, is_valid_name(n))).collect();
        assert_eq!(got, cases.to_vec());
    }

    #[test]
    fn resolution_order() {
        let dir = std::env::temp_dir().join(format!("mapo-instance-test-{}", std::process::id()));
        let wt = dir.join("mapo-native");
        let bin = wt.join("target/debug");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(wt.join(".git"), "gitdir: elsewhere\n").unwrap();
        let exe = bin.join("mapo");
        std::fs::write(&exe, "").unwrap();
        let outside = dir.join("bin/mapo");
        std::fs::create_dir_all(outside.parent().unwrap()).unwrap();
        std::fs::write(&outside, "").unwrap();

        let pick = |r: Result<Instance, InstanceError>| r.map(|i| (i.name, i.source)).ok();
        let got = [
            pick(resolve(Some("drive-x"), Some("env-x"), &exe)),
            pick(resolve(None, Some("env-x"), &exe)),
            pick(resolve(None, None, &exe)),
            pick(resolve(None, None, &outside)),
            pick(resolve(Some("Bad_Name"), None, &exe)),
        ];
        assert_eq!(
            got,
            [
                Some(("drive-x".to_owned(), Source::Flag)),
                Some(("env-x".to_owned(), Source::Env)),
                Some(("dev-mapo-native".to_owned(), Source::Worktree)),
                Some(("main".to_owned(), Source::Default)),
                None,
            ]
        );
        let main = resolve(Some("main"), None, &exe).unwrap();
        assert!(main.refuse_main_from_worktree().is_err());
        let bad = dir.join("Mapo_Native");
        std::fs::create_dir_all(bad.join("target")).unwrap();
        std::fs::write(bad.join(".git"), "").unwrap();
        std::fs::write(bad.join("target/mapo"), "").unwrap();
        assert!(matches!(
            resolve(None, None, &bad.join("target/mapo")),
            Err(InstanceError::InvalidWorktreeName { .. })
        ));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
