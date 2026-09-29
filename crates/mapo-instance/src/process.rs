//! Process identity checks, so Mapo only ever signals processes it started.

use std::path::{Path, PathBuf};

/// Whether a process with this pid exists (it may belong to anyone).
pub fn process_alive(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    match rustix::process::Pid::from_raw(pid) {
        Some(p) => rustix::process::test_kill_process(p).is_ok_and(|()| true) || is_eperm(p),
        None => false,
    }
}

fn is_eperm(p: rustix::process::Pid) -> bool {
    matches!(rustix::process::test_kill_process(p), Err(e) if e == rustix::io::Errno::PERM)
}

/// The executable path of a running process.
#[allow(unsafe_code)]
pub fn process_exe(pid: i32) -> Option<PathBuf> {
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: proc_pidpath writes at most buf.len() bytes into a buffer we own.
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if n <= 0 {
        return None;
    }
    buf.truncate(n as usize);
    String::from_utf8(buf).ok().map(PathBuf::from)
}

/// The argv of a running process, read with `sysctl(KERN_PROCARGS2)`.
#[allow(unsafe_code)]
pub fn process_args(pid: i32) -> Option<Vec<String>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size: libc::size_t = 0;
    // SAFETY: a size query with a null buffer; mib is a valid 3-element array.
    let rc = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 || size < 4 {
        return None;
    }
    let mut buf = vec![0u8; size];
    // SAFETY: buf holds `size` bytes, and sysctl writes at most that many and updates size.
    let rc = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return None;
    }
    buf.truncate(size);
    parse_procargs2(&buf)
}

/// Layout: argc (i32), exec path, NUL padding, then argc NUL-terminated strings.
fn parse_procargs2(buf: &[u8]) -> Option<Vec<String>> {
    let argc = i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?);
    let mut rest = buf.get(4..)?;
    let end = rest.iter().position(|&b| b == 0)?;
    rest = &rest[end..];
    let start = rest.iter().position(|&b| b != 0)?;
    rest = &rest[start..];
    let args: Vec<String> = rest
        .split(|&b| b == 0)
        .take(usize::try_from(argc).ok()?)
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect();
    Some(args)
}

/// True when `pid` still runs `exe` and its argv contains every string in `needles`.
pub fn process_matches(pid: i32, exe: &Path, needles: &[&str]) -> bool {
    let Some(actual) = process_exe(pid) else {
        return false;
    };
    let same = std::fs::canonicalize(&actual).unwrap_or(actual)
        == std::fs::canonicalize(exe).unwrap_or(exe.into());
    if !same {
        return false;
    }
    let Some(args) = process_args(pid) else {
        return false;
    };
    needles.iter().all(|n| args.iter().any(|a| a == n))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_process() {
        let pid = std::process::id() as i32;
        let exe = std::env::current_exe().unwrap();
        assert!(process_alive(pid));
        assert!(!process_alive(0));
        assert_eq!(
            process_exe(pid).map(|p| std::fs::canonicalize(p).unwrap()),
            Some(std::fs::canonicalize(&exe).unwrap())
        );
        let args = process_args(pid).unwrap();
        assert!(!args.is_empty());
        assert!(process_matches(pid, &exe, &[]));
        assert!(!process_matches(pid, Path::new("/bin/ls"), &[]));
        assert!(!process_matches(pid, &exe, &["--definitely-not-an-arg"]));
    }

    #[test]
    fn procargs_layout() {
        let mut buf = 2i32.to_ne_bytes().to_vec();
        buf.extend_from_slice(b"/bin/x\0\0\0/bin/x\0--flag\0ENV=1\0");
        assert_eq!(
            parse_procargs2(&buf),
            Some(vec!["/bin/x".to_owned(), "--flag".to_owned()])
        );
    }
}
