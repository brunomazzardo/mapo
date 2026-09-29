//! Pid files: line 1 the pid, line 2 the executable path (ENGINEERING §2.2).

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use crate::InstanceError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PidFile {
    pub pid: i32,
    pub exe: PathBuf,
}

pub fn read_pid_file(path: &Path) -> Option<PidFile> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut lines = text.lines();
    let pid = lines.next()?.trim().parse().ok()?;
    let exe = PathBuf::from(lines.next().unwrap_or_default().trim());
    Some(PidFile { pid, exe })
}

/// Writes the pid file atomically with mode 0600.
pub fn write_pid_file(path: &Path, pid: i32, exe: &Path) -> Result<(), InstanceError> {
    let tmp = path.with_extension(format!("tmp.{pid}"));
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| InstanceError::io(format!("write {}", tmp.display()), e))?;
    writeln!(f, "{pid}\n{}", exe.display())
        .map_err(|e| InstanceError::io(format!("write {}", tmp.display()), e))?;
    std::fs::rename(&tmp, path)
        .map_err(|e| InstanceError::io(format!("rename to {}", path.display()), e))
}

/// Removes the pid file if it still names `pid`.
pub fn remove_pid_file(path: &Path, pid: i32) {
    if read_pid_file(path).is_some_and(|p| p.pid == pid) {
        let _ = std::fs::remove_file(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let path = std::env::temp_dir().join(format!("mapo-pid-test-{}.pid", std::process::id()));
        write_pid_file(&path, 42, Path::new("/x/mapo")).unwrap();
        assert_eq!(
            read_pid_file(&path),
            Some(PidFile {
                pid: 42,
                exe: PathBuf::from("/x/mapo")
            })
        );
        remove_pid_file(&path, 41);
        assert!(path.exists());
        remove_pid_file(&path, 42);
        assert!(!path.exists());
    }
}
