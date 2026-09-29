//! The environment of a tab's shell (PLAN T0.5 step 2, REQUIREMENTS R-TAB-4, contract 11).

use std::path::{Path, PathBuf};

/// Where the daemon finds its resources and the `mapo` it puts first on PATH (ENGINEERING §3.3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resources {
    /// `resources/` in a worktree, `Contents/Resources/` in a bundle.
    pub dir: PathBuf,
    /// The directory holding the `mapo` tabs should run.
    pub bin_dir: PathBuf,
}

impl Resources {
    /// Derives the resource and bin dirs from the daemon's own executable.
    pub fn from_exe(exe: &Path) -> Self {
        let real = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
        let exe_dir = real.parent().map(Path::to_path_buf).unwrap_or_default();
        if exe_dir.ends_with("Contents/Helpers")
            && let Some(contents) = exe_dir.parent()
        {
            return Self {
                dir: contents.join("Resources"),
                bin_dir: contents.join("Resources/bin"),
            };
        }
        let root = real
            .ancestors()
            .find(|d| d.join(".git").exists())
            .map(Path::to_path_buf)
            .unwrap_or_else(|| exe_dir.clone());
        Self {
            dir: root.join("resources"),
            bin_dir: exe_dir,
        }
    }

    pub fn zsh_dir(&self) -> PathBuf {
        self.dir.join("shell-integration/zsh")
    }

    pub fn terminfo_dir(&self) -> PathBuf {
        self.dir.join("terminfo")
    }

    pub fn has_ghostty_terminfo(&self) -> bool {
        self.terminfo_dir().join("78/xterm-ghostty").is_file()
    }
}

/// Per-tab values for R-TAB-4.
pub struct TabIdentity<'a> {
    pub instance: &'a str,
    pub workspace_id: &'a str,
    pub tab_id: &'a str,
    pub tab_name: &'a str,
    pub token: &'a str,
    pub hook_token: &'a str,
}

fn dropped(key: &str) -> bool {
    const PREFIXES: &[&str] = &[
        "MAPO_",
        // Every CLAUDE* marker: the overnight agent itself runs inside Claude Code (contract 11).
        "CLAUDE",
        "GHOSTTY_",
        "TERM_PROGRAM",
        "TERMINFO",
        "ITERM_",
        "KITTY_",
        "VSCODE_",
        "TMUX",
    ];
    const EXACT: &[&str] = &[
        "SHLVL", "COLUMNS", "LINES", "PWD", "OLDPWD", "TERM", "ZDOTDIR",
    ];
    PREFIXES.iter().any(|p| key.starts_with(p)) || EXACT.contains(&key)
}

/// Builds the environment from `inherited`: drops every leaked session marker, then sets Mapo's.
pub fn build(
    inherited: impl IntoIterator<Item = (String, String)>,
    id: &TabIdentity<'_>,
    res: &Resources,
) -> Vec<(String, String)> {
    let inherited: Vec<(String, String)> = inherited.into_iter().collect();
    let get = |k: &str| {
        inherited
            .iter()
            .find(|(key, _)| key == k)
            .map(|(_, v)| v.clone())
    };
    let old_zdotdir = get("ZDOTDIR");
    let path = get("PATH").unwrap_or_else(|| "/usr/bin:/bin:/usr/sbin:/sbin".into());
    let mut env: Vec<(String, String)> =
        inherited.into_iter().filter(|(k, _)| !dropped(k)).collect();
    let bin = res.bin_dir.display().to_string();
    let (term, terminfo) = if res.has_ghostty_terminfo() {
        (
            "xterm-ghostty",
            Some(res.terminfo_dir().display().to_string()),
        )
    } else {
        ("xterm-256color", None)
    };
    let mut set = vec![
        ("MAPO_INSTANCE", id.instance.to_owned()),
        ("MAPO_WORKSPACE_ID", id.workspace_id.to_owned()),
        ("MAPO_TAB_ID", id.tab_id.to_owned()),
        ("MAPO_TAB_NAME", id.tab_name.to_owned()),
        ("MAPO_TOKEN", id.token.to_owned()),
        ("MAPO_HOOK_TOKEN", id.hook_token.to_owned()),
        ("MAPO_BIN_DIR", bin.clone()),
        ("PATH", format!("{bin}:{path}")),
        ("TERM", term.to_owned()),
        ("TERM_PROGRAM", "ghostty".to_owned()),
        ("COLORTERM", "truecolor".to_owned()),
        ("ZDOTDIR", res.zsh_dir().display().to_string()),
    ];
    if let Some(ti) = terminfo {
        set.push(("TERMINFO", ti));
    }
    if let Some(z) = old_zdotdir {
        set.push(("MAPO_ZSH_ZDOTDIR", z));
    }
    if !env.iter().any(|(k, _)| k == "LANG") {
        set.push(("LANG", "en_US.UTF-8".to_owned()));
    }
    env.retain(|(k, _)| !set.iter().any(|(s, _)| s == k));
    env.extend(set.into_iter().map(|(k, v)| (k.to_owned(), v)));
    env.sort();
    env
}

/// The login shell: `$SHELL`, else the passwd entry, else `/bin/zsh`.
pub fn login_shell(configured: Option<&str>) -> String {
    configured
        .map(str::to_owned)
        .or_else(|| std::env::var("SHELL").ok().filter(|s| !s.is_empty()))
        .unwrap_or_else(|| "/bin/zsh".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn env_scrubs_and_sets() {
        let inherited = [
            ("HOME", "/Users/u"),
            ("PATH", "/usr/bin"),
            ("MAPO_TAB_ID", "frozen"),
            ("MAPO_AGENT_TOKEN", "frozen"),
            ("CLAUDECODE", "1"),
            ("CLAUDE_CODE_ENTRYPOINT", "cli"),
            ("TERM_PROGRAM", "iTerm.app"),
            ("SHLVL", "3"),
            ("ZDOTDIR", "/Users/u/.config/zsh"),
            ("LANG", "pt_BR.UTF-8"),
        ]
        .map(|(k, v)| (k.to_owned(), v.to_owned()));
        let res = Resources {
            dir: PathBuf::from("/r"),
            bin_dir: PathBuf::from("/b"),
        };
        let id = TabIdentity {
            instance: "dev-x",
            workspace_id: "w",
            tab_id: "t",
            tab_name: "n",
            token: "tok",
            hook_token: "htok",
        };
        let got: Vec<String> = build(inherited, &id, &res)
            .into_iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect();
        assert_eq!(
            got,
            [
                "COLORTERM=truecolor",
                "HOME=/Users/u",
                "LANG=pt_BR.UTF-8",
                "MAPO_BIN_DIR=/b",
                "MAPO_HOOK_TOKEN=htok",
                "MAPO_INSTANCE=dev-x",
                "MAPO_TAB_ID=t",
                "MAPO_TAB_NAME=n",
                "MAPO_TOKEN=tok",
                "MAPO_WORKSPACE_ID=w",
                "MAPO_ZSH_ZDOTDIR=/Users/u/.config/zsh",
                "PATH=/b:/usr/bin",
                "TERM=xterm-256color",
                "TERM_PROGRAM=ghostty",
                "ZDOTDIR=/r/shell-integration/zsh",
            ]
        );
    }
}
