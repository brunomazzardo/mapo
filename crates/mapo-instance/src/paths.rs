//! Per-instance paths and the private directories that hold them (ENGINEERING §2.2).

use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::InstanceError;

/// Every path an instance uses.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Paths {
    pub data_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub socket: PathBuf,
    pub lock: PathBuf,
    pub pid_file: PathBuf,
    pub app_pid_file: PathBuf,
    pub state_db: PathBuf,
    pub config: PathBuf,
    pub token: PathBuf,
    pub log_dir: PathBuf,
    pub recovery_dir: PathBuf,
}

impl Paths {
    pub fn for_instance(name: &str) -> Result<Self, InstanceError> {
        Ok(Self::with_roots(name, &data_root()?, &runtime_dir()?))
    }

    pub fn with_roots(name: &str, data_root: &Path, runtime_dir: &Path) -> Self {
        let data_dir = data_root.join(name);
        Self {
            socket: runtime_dir.join(format!("{name}.sock")),
            lock: runtime_dir.join(format!("{name}.lock")),
            pid_file: runtime_dir.join(format!("{name}.pid")),
            app_pid_file: runtime_dir.join(format!("{name}.app.pid")),
            runtime_dir: runtime_dir.to_path_buf(),
            state_db: data_dir.join("state.db"),
            config: data_dir.join("config.toml"),
            token: data_dir.join("app.token"),
            log_dir: data_dir.join("logs"),
            recovery_dir: data_dir.join("recovery"),
            data_dir,
        }
    }

    /// Creates the data, log and runtime directories with mode 0700.
    pub fn ensure_dirs(&self) -> Result<(), InstanceError> {
        for dir in [&self.data_dir, &self.log_dir, &self.runtime_dir] {
            ensure_private_dir(dir)?;
        }
        Ok(())
    }
}

/// `~/Library/Application Support/dev.mapo.app/instances`.
pub fn data_root() -> Result<PathBuf, InstanceError> {
    let home = std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .ok_or_else(|| InstanceError::Unsafe {
            path: PathBuf::from("$HOME"),
            message: "HOME is not set".into(),
        })?;
    Ok(PathBuf::from(home).join("Library/Application Support/dev.mapo.app/instances"))
}

/// `$(getconf DARWIN_USER_TEMP_DIR)mapo`, the per-user runtime directory.
pub fn runtime_dir() -> Result<PathBuf, InstanceError> {
    Ok(darwin_user_temp_dir()?.join("mapo"))
}

#[allow(unsafe_code)]
fn darwin_user_temp_dir() -> Result<PathBuf, InstanceError> {
    let mut buf = vec![0u8; 1024];
    // SAFETY: confstr writes at most buf.len() bytes, NUL-terminated, into a buffer we own.
    let n = unsafe {
        libc::confstr(
            libc::_CS_DARWIN_USER_TEMP_DIR,
            buf.as_mut_ptr().cast(),
            buf.len(),
        )
    };
    if n == 0 || n > buf.len() {
        return Err(InstanceError::io(
            "confstr(_CS_DARWIN_USER_TEMP_DIR)",
            std::io::Error::last_os_error(),
        ));
    }
    buf.truncate(n - 1);
    let s = String::from_utf8(buf).map_err(|_| InstanceError::Unsafe {
        path: PathBuf::from("DARWIN_USER_TEMP_DIR"),
        message: "not UTF-8".into(),
    })?;
    Ok(PathBuf::from(s))
}

/// Creates `dir` (and parents) and makes it 0700. Refuses a directory owned by another user.
pub fn ensure_private_dir(dir: &Path) -> Result<(), InstanceError> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| InstanceError::io(format!("create {}", dir.display()), e))?;
    let meta = std::fs::symlink_metadata(dir)
        .map_err(|e| InstanceError::io(format!("stat {}", dir.display()), e))?;
    if !meta.is_dir() {
        return Err(InstanceError::Unsafe {
            path: dir.to_path_buf(),
            message: "is not a directory".into(),
        });
    }
    let uid = rustix::process::geteuid().as_raw();
    if meta.uid() != uid {
        return Err(InstanceError::Unsafe {
            path: dir.to_path_buf(),
            message: format!("is owned by uid {}, not {uid}", meta.uid()),
        });
    }
    if meta.mode() & 0o777 != 0o700 {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| InstanceError::io(format!("chmod {}", dir.display()), e))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout() {
        let p = Paths::with_roots("dev-x", Path::new("/d"), Path::new("/r"));
        let got = serde_json::to_value(&p).unwrap();
        assert_eq!(
            got,
            serde_json::json!({
                "dataDir": "/d/dev-x", "runtimeDir": "/r", "socket": "/r/dev-x.sock", "lock": "/r/dev-x.lock",
                "pidFile": "/r/dev-x.pid", "appPidFile": "/r/dev-x.app.pid", "stateDb": "/d/dev-x/state.db",
                "config": "/d/dev-x/config.toml", "token": "/d/dev-x/app.token", "logDir": "/d/dev-x/logs",
                "recoveryDir": "/d/dev-x/recovery"
            })
        );
    }

    #[test]
    fn runtime_dir_is_user_temp() {
        let dir = runtime_dir().unwrap();
        assert!(dir.ends_with("mapo"));
        assert!(dir.to_string_lossy().contains("/T/"));
    }
}
