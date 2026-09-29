//! Processes and ports (ARCHITECTURE §3.6, PLAN T4.1 and T4.2): the processes on a tab's TTY, their
//! listening TCP ports, process identities, and a guarded stop. Scans run only when asked.

use libproc::libproc::bsd_info::BSDInfo;
use libproc::libproc::file_info::{ListFDs, ProcFDType, pidfdinfo};
use libproc::libproc::net_info::{SocketFDInfo, SocketInfoKind};
use libproc::libproc::proc_pid::{listpidinfo, pidinfo, pidpath};
use libproc::processes::{ProcFilter, pids_by_type};

/// TCP state LISTEN in `tcpsi_state` (`TSI_S_LISTEN`).
const TCP_LISTEN: i32 = 1;

/// One listening socket and its owner.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Listener {
    pub port: u16,
    pub pid: u32,
    pub name: String,
    pub exe: String,
    /// Stable for one process: changes when the pid is reused (pid, start time, executable).
    pub identity: String,
    /// The controlling terminal's device, used to map the process to a tab.
    #[serde(skip)]
    pub tty: Option<u32>,
    #[serde(skip)]
    pub ppid: u32,
}

fn bsd(pid: u32) -> Option<BSDInfo> {
    pidinfo::<BSDInfo>(pid as i32, 0).ok()
}

/// The controlling terminal device of `pid`, if it has one.
pub fn tty_of(pid: u32) -> Option<u32> {
    bsd(pid)
        .map(|i| i.e_tdev)
        .filter(|t| *t != 0 && *t != u32::MAX)
}

/// Every process on `tty` (the shell and its jobs).
pub fn pids_on_tty(tty: u32) -> Vec<u32> {
    pids_by_type(ProcFilter::ByTTY { tty })
        .unwrap_or_default()
        .into_iter()
        .filter(|p| *p != 0)
        .collect()
}

/// The TCP ports `pid` listens on.
#[allow(unsafe_code)]
pub fn listening_ports(pid: u32) -> Vec<u16> {
    let Some(info) = bsd(pid) else {
        return vec![];
    };
    let Ok(fds) = listpidinfo::<ListFDs>(pid as i32, info.pbi_nfiles as usize) else {
        return vec![];
    };
    let mut ports = Vec::new();
    for fd in fds {
        if !matches!(fd.proc_fdtype.into(), ProcFDType::Socket) {
            continue;
        }
        let Ok(socket) = pidfdinfo::<SocketFDInfo>(pid as i32, fd.proc_fd) else {
            continue;
        };
        if !matches!(socket.psi.soi_kind.into(), SocketInfoKind::Tcp) {
            continue;
        }
        // SAFETY: soi_kind says the union holds TCP info.
        let tcp = unsafe { socket.psi.soi_proto.pri_tcp };
        if tcp.tcpsi_state != TCP_LISTEN {
            continue;
        }
        let raw = tcp.tcpsi_ini.insi_lport as u32;
        let port = (((raw >> 8) & 0xff) | ((raw << 8) & 0xff00)) as u16;
        if port != 0 && !ports.contains(&port) {
            ports.push(port);
        }
    }
    ports.sort_unstable();
    ports
}

/// The listening ports of every process on the terminal of `shell_pid` (a tab's server ports).
pub fn tab_ports(shell_pid: u32) -> Vec<u16> {
    let Some(tty) = tty_of(shell_pid) else {
        return vec![];
    };
    let mut ports: Vec<u16> = pids_on_tty(tty)
        .into_iter()
        .flat_map(listening_ports)
        .collect();
    ports.sort_unstable();
    ports.dedup();
    ports
}

/// A process identity: FNV-1a over pid, start time and executable path.
pub fn identity(pid: u32) -> Option<String> {
    let info = bsd(pid)?;
    let exe = pidpath(pid as i32).unwrap_or_default();
    Some(identity_of(
        pid,
        info.pbi_start_tvsec,
        info.pbi_start_tvusec,
        &exe,
    ))
}

fn identity_of(pid: u32, sec: u64, usec: u64, exe: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in pid
        .to_le_bytes()
        .iter()
        .chain(&sec.to_le_bytes())
        .chain(&usec.to_le_bytes())
        .chain(exe.as_bytes())
    {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

/// Every TCP listener owned by `uid`.
pub fn listeners(uid: u32) -> Vec<Listener> {
    let mut out = Vec::new();
    for pid in pids_by_type(ProcFilter::ByUID { uid }).unwrap_or_default() {
        if pid == 0 {
            continue;
        }
        let ports = listening_ports(pid);
        if ports.is_empty() {
            continue;
        }
        let Some(info) = bsd(pid) else { continue };
        let exe = pidpath(pid as i32).unwrap_or_default();
        let name = exe.rsplit('/').next().unwrap_or_default().to_owned();
        let identity = identity_of(pid, info.pbi_start_tvsec, info.pbi_start_tvusec, &exe);
        let tty = Some(info.e_tdev).filter(|t| *t != 0 && *t != u32::MAX);
        for port in ports {
            out.push(Listener {
                port,
                pid,
                name: name.clone(),
                exe: exe.clone(),
                identity: identity.clone(),
                tty,
                ppid: info.pbi_ppid,
            });
        }
    }
    out.sort_by_key(|l| (l.port, l.pid));
    out
}

/// The parent of `pid`.
pub fn parent(pid: u32) -> Option<u32> {
    bsd(pid).map(|i| i.pbi_ppid).filter(|p| *p != 0)
}

/// Whether `pid` is `ancestor` or one of its descendants (walking up the parent chain).
pub fn descends_from(pid: u32, ancestor: u32) -> bool {
    let mut p = Some(pid);
    for _ in 0..64 {
        match p {
            Some(x) if x == ancestor => return true,
            Some(x) if x > 1 => p = parent(x),
            _ => return false,
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_changes_with_any_input() {
        let base = identity_of(42, 100, 5, "/bin/nc");
        let got = [
            identity_of(42, 100, 5, "/bin/nc") == base,
            identity_of(43, 100, 5, "/bin/nc") == base,
            identity_of(42, 101, 5, "/bin/nc") == base,
            identity_of(42, 100, 6, "/bin/nc") == base,
            identity_of(42, 100, 5, "/bin/sh") == base,
        ];
        assert_eq!(got, [true, false, false, false, false]);
    }

    #[test]
    fn finds_own_listener() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let me = std::process::id();
        assert!(listening_ports(me).contains(&port));
        assert!(identity(me).is_some());
    }
}
