# Mapo native core: Rust crates and macOS integration research

Researched 2026-09-28. Crate versions and dates come from the crates.io API on that day; repo activity comes from the GitHub API. Claude Code facts come from code.claude.com docs (CLI 2.1.284, released 2026-09-28) and from the cmux and Superset source trees.

---

## 0. Recommendations at a glance

| Concern | Pick | Why (one line) |
|---|---|---|
| PTY allocation | `pty-process` 0.5.3 (async feature) or `rustix` 1.1.5 `pty` + `pre_exec` | Tokio-native `AsyncRead/AsyncWrite` master, and the child gets `setsid` + controlling tty for you. `portable-pty` 0.9.0 also works, but only blocking. |
| Signals / groups | `rustix` 1.1.5 (`kill_process_group`, `tcgetpgrp`) or `nix` 0.31.3 | Thin, safe syscall wrappers. |
| Non-PTY supervised children | `process-wrap` 10.0.1 (`ProcessGroup::leader()`, `KillOnDrop`) | Successor to `command-group`, tokio support, group kill. |
| Headless screen state in core | `alacritty_terminal` 0.26.0 (pure Rust, Zed uses it). `libghostty-vt` 0.2.2 if the UI also uses Ghostty. | Needed for `read_screen`, `wait_for`, snapshot-on-attach, OSC 7/133. |
| OSC side-channel parsing | `vte` 0.15.0 | Catches OSC 7 (cwd), 133 (prompt/exit code), 9/99/777 (notify) on the raw stream. |
| Process info / ports | `libproc` 0.14.11 plus `listeners` 0.6.1. `sysinfo` 0.39.6 when you need convenience. | Direct `proc_pidinfo`/`proc_pidfdinfo`, no `lsof` spawning. |
| MCP | `rmcp` 3.5.0 (official), stdio transport inside `mapo mcp` | Official SDK. Stdio gets a 30-minute idle timeout in Claude Code, versus 5 minutes for HTTP. |
| CLI/UI ↔ core IPC | `tokio::net::UnixListener` + `tokio-util` 0.7.19 codecs + `serde_json` | Hand-rolled framed JSON-RPC. `jsonrpsee` is HTTP/WS and `tarpc` is Rust-only. |
| FS watching | `notify` 8.2.0 (9.0.0-rc.5 is close) + `notify-debouncer-full` 0.7.0 | FSEvents backend, rename stitching. |
| Gitignore-aware walking | `ignore` 0.4.33 | ripgrep's walker; Zed uses it too. |
| Fuzzy finding | `nucleo` 0.5.0 / `nucleo-matcher` 0.3.1 (alt: `frizbee` 0.13.0) | Helix and Zed use nucleo. frizbee is the newer SIMD alternative. |
| Git | `gix` 0.88.0 for cheap reads plus the `git` CLI for status and diffs | Zed dropped git2 and shells out for status. gix status lacks the fsmonitor and untracked-cache accelerators. |
| Diff hunks | `imara-diff` 0.2.0 or `similar` 3.2.0 | Fast Myers/histogram. |
| mprocs config | `serde-saphyr` 1.3.0 or `serde_yaml` 0.9 (deprecated but works) + the `schemas/mprocs.json` shape | mprocs became **dekit** (v0.10.0, released 2026-09-28). |
| Swift ↔ Rust | Socket protocol if you run a daemon. Otherwise `uniffi` 0.32.2 (or `swift-bridge` 0.1.59 / `cbindgen` 0.29.4). | A daemon removes most of the FFI surface. |

**Session persistence.** A small Rust daemon (`mapod`) owns every PTY and supervised process. The Swift app, the `mapo` CLI and the MCP adapter are all clients of it. Layer cmux-style relaunch-restore on top for reboots and daemon crashes. Section 1.5 has the details.

**Claude Code.** Keep the real interactive TUI in a PTY. Inject integration through **`CLAUDE_CODE_PLUGIN_DIRS`** (CLI v2.1.280+, released 2026-09-22), set in every PTY's environment and pointing at a Mapo plugin inside the app bundle. The plugin carries the hooks, the MCP server and a skill. Section 5 has the details.

---

## 1. PTY and process supervision

### 1.1 PTY crates

| Crate | Version (date) | Notes |
|---|---|---|
| [`portable-pty`](https://docs.rs/portable-pty) | 0.9.0 (2025-02-11) | Part of the wezterm monorepo (active, pushed 2026-09-28). Blocking API: `try_clone_reader()` gives a `Box<dyn Read>` that you read on a thread. `MasterPty` has `resize/get_size/process_group_leader/as_raw_fd/tty_name`; `Child` has `try_wait/kill/wait/process_id/clone_killer`. About 9.2M recent downloads. |
| [`pty-process`](https://docs.rs/pty-process) | 0.5.3 (2025-07-12) | Wraps `tokio::process::Command`. The `async` feature makes `Pty` implement `AsyncRead + AsyncWrite`. The child becomes session leader with the PTY as its controlling tty. Builder methods take `self` by value. Small project (32 stars) but simple code. |
| [`rustix`](https://docs.rs/rustix) | 1.1.5 (2026-09-16) | `rustix::pty::{openpt, grantpt, unlockpt, ptsname}`, `rustix::process::{setsid, ioctl_tiocsctty, kill_process_group}`, `rustix::termios::tcgetpgrp`. dekit (the mprocs successor) builds its own PTYs on `rustix` `all-apis`. |
| [`rustix-openpty`](https://crates.io/crates/rustix-openpty) | 0.2.0 (2025-03-06) | `openpty()` convenience on top of rustix. |
| [`nix`](https://docs.rs/nix) | 0.31.3 (2026-05-11) | `nix::pty::openpty/forkpty`, `killpg`. Zed pins nix 0.30. |
| `alacritty_terminal::tty` | 0.26.0 (2026-04-06) | PTY plus event loop plus emulator in one. Zed uses a fork. It's heavier if you only want the PTY. |

Async spawn sketch (pty-process 0.5, `features = ["async"]`):

```rust
let (mut pty, pts) = pty_process::open()?;
pty.resize(pty_process::Size::new(rows, cols))?;
let child = pty_process::Command::new("/bin/zsh")
    .arg("-l")
    .current_dir(&cwd)
    .env("MAPO_TAB_ID", &tab_id)
    .env("MAPO_SOCKET", &sock)
    .env("CLAUDE_CODE_PLUGIN_DIRS", &plugin_dirs) // see §5
    .spawn(pts)?;                                  // setsid + TIOCSCTTY
// pty: tokio AsyncRead/AsyncWrite; child: tokio::process::Child
```

kqueue-based readiness on a PTY master works on macOS; alacritty and wezterm both rely on it. `poll(2)` on devices is the call that's broken on macOS, so let tokio/mio use kqueue.

### 1.2 Process groups, signals, killing trees (macOS)

- A PTY child is a **session leader** with pgid == pid. Interactive shells with job control move each foreground job into **its own process group**, so `killpg(shell_pgid)` does not reach it.
- To find the current foreground job, call `tcgetpgrp(master_fd)`. iTerm2 uses the same trick to name tabs, and it tells you whether `claude` or `vim` is in front.
- To enumerate everything in a tab, use `libproc::processes::pids_by_type(ProcFilter::ByTTY{tty})`, which returns every process whose controlling tty is that PTY, whatever its pgrp. Other filters: `ByProgramGroup{pgrpid}` and `ByParentProcess{ppid}`. You can also build a ppid map from `proc_listallpids` + `PROC_PIDTBSDINFO` (`pbi_ppid`, `pbi_pgid`, `pbi_start_tvsec`).
- A robust tab kill:
  1. Close the PTY master. The kernel sends SIGHUP to the session, and zsh/bash forward HUP to their jobs.
  2. SIGTERM every remaining pgrp found by `ByTTY` plus a descendant walk.
  3. Wait for a grace period (for example 3 s), then SIGKILL.
- Processes that daemonize (double-fork, reparent to launchd, `setsid`) escape both the tree and the tty. macOS has no cgroups, so accept this.
- **Server tabs**: spawn the server directly, without an interactive shell, either with no PTY via `process-wrap` `ProcessGroup::leader()` or with a PTY and no job control. The whole tree then shares one pgrp and `killpg` is enough. dekit does this by default: *"mprocs sent stop signals to the main process only; dekit sends them to the whole process group unless `group: false`."*
- **PID reuse safety for "safe kill"**: identify processes by `(pid, start_time)` from `proc_bsdinfo.pbi_start_tvsec/usec`, plus the executable path. Re-verify immediately before `kill`. cmux added the same kind of "PID-birth token" to its Ghostty fork ([manaflow-ai/ghostty#229](https://github.com/manaflow-ai/ghostty/pull/229)).
- [`process-wrap`](https://docs.rs/process-wrap) 10.0.1 (2026-09-23, watchexec) has composable wrappers: `ProcessGroup`, `ProcessSession`, `ResetSigmask`, `KillOnDrop` (tokio). `kill()` on a group-wrapped child signals the group. It is the successor of `command-group` (5.0.1, 2023, stale). rmcp's child-process transport depends on it.

### 1.3 Restart policies (reference designs)

- **dekit** (mprocs successor) task keys: `autorestart: never|on-failure|always`, `ready: {log|tcp|http|cmd}`, `deps`, `stop: SIGTERM | {signal, group, keys, cmd, timeout}`, `type: service|job`. Task states are `idle, starting, running, ready, stopping, backoff, done, exited`. Last exit is reported as `exit_code | signal` plus `reason: "ready_timeout"`. ([docs/config/tasks.md](https://github.com/pvolok/mprocs/blob/main/src/docs/config/tasks.md))
- **mprocs.yaml** `autorestart: true` means *"If process exits within 1 second of starting, it will not be restarted."*
- **process-compose** v1.122.0 (2026-08-17, Go) uses `availability.restart: on_failure|always|exit_on_failure|no` with `backoff_seconds` and `max_restarts`, readiness/liveness probes, and `depends_on` conditions.
- For Mapo, copy dekit's state vocabulary and add exponential backoff with a cap, a crash-loop window (N failures in M seconds → `failed`), and readiness from log regex, TCP connect or HTTP GET. Those feed the "wait for output patterns" API.

### 1.4 Headless terminal state inside the core

You need a screen model in the core (not only in the UI) for `read_screen`, `wait_for(pattern)`, scrollback snapshots, OSC 7 (cwd) and OSC 133 (command start/end and exit code, which is how "run a command and get its exit code" works).

| Crate | Version (date) | Notes |
|---|---|---|
| [`alacritty_terminal`](https://docs.rs/alacritty_terminal) | 0.26.0 (2026-04-06) | Mature and pure Rust. Zed uses it (a forked rev). The Zed daemon RFC serializes `TermState` for snapshots. |
| [`libghostty-vt`](https://github.com/uzaaft/libghostty-rs) | 0.2.2 (2026-09-28) | Safe Rust wrapper over Ghostty's VT core: `Terminal`, `RenderState`, `KeyEncoder`, `MouseEncoder`. Needs a **Zig 0.16 toolchain** and pins a Ghostty commit. Pre-1.0: *"do not guarantee compatibility with arbitrary installed C API revisions."* zmx uses libghostty-vt to rehydrate clients on re-attach. |
| [`vt100`](https://docs.rs/vt100) | 0.16.2 (2025-07-12) | Simple screen model by the pty-process author. |
| [`avt`](https://crates.io/crates/avt) | 0.18.0 (2026-05-05) | asciinema's virtual terminal. |
| [`vte`](https://docs.rs/vte) | 0.15.0 (2025-02-02) | The parser. Implement `Perform::osc_dispatch` to tap OSC 7/133/9/99/777 whatever emulator you use. |

### 1.5 Session persistence: what others do

| Product | Model | Processes survive app quit? |
|---|---|---|
| **cmux** (Swift/AppKit + libghostty) | No local PTY daemon. Restores windows, workspaces, panes, cwd and best-effort scrollback, then re-runs each agent's native resume command (`claude --resume <id>`) from `~/.cmuxterm/<agent>-hook-sessions.json`. There's an opt-in `local-tmux` for live processes. "Agent Hibernation" SIGTERMs idle agents' pgrp and resumes them on focus. ([session-restore docs](https://cmux.com/docs/session-restore), [docs/agent-hooks.md](https://github.com/manaflow-ai/cmux/blob/main/docs/agent-hooks.md)) | No |
| **Ghostty** | `window-save-state` restores position, tabs, splits and cwd (cwd needs shell integration). No process persistence. | No |
| **Warp** | Windows, tabs, panes and recent blocks go to SQLite ([docs](https://docs.warp.dev/terminal/sessions/session-restoration/)). Processes are not restored. | No |
| **Zed** | Owns the PTY master in-process, so everything dies with SIGHUP. An RFC (2026-03-03, [discussion #50584](https://github.com/zed-industries/zed/discussions/50584)) proposes a per-terminal `pty_host` daemon: fork+detach, a Unix socket, framed binary protocol (1-byte tag + 4-byte LE length), and a headless `alacritty_terminal::Term` snapshot sent on reconnect. Not merged. The author has used it daily for 6 months. | No (RFC) |
| **VS Code** (Mapo today) | A pty host process survives window reloads. On app quit, `persistentSessionReviveProcess` restores the buffer and **re-creates** processes. | Reload yes, quit no |
| **WezTerm** | `wezterm-mux-server` with `unix_domains`. The GUI does `wezterm connect unix`, and panes live in the daemon ([docs](https://wezterm.org/multiplexing.html)). | Yes |
| **Superset** (Electron agent IDE) | A "terminal host daemon" (a persistent Node process) owns the PTYs plus a headless xterm, and talks NDJSON over a Unix socket. Their plan docs record two lessons. Head-of-line blocking: output floods delayed `createOrAttach` RPCs, so they split **control vs stream sockets**. Stale daemons from older app versions: they added protocol-version negotiation and an authenticated shutdown of the old daemon ([plan](https://github.com/superset-sh/superset/blob/main/apps/desktop/plans/done/20260106-1800-terminal-host-control-stream-sockets.md)). | Yes |
| **dekit** (ex-mprocs) | A per-project **runner** process owns tasks, terminals and logs, and outlives the terminal. The RPC framing is `len:u32_be, kind:u8 (0x00 JSON ctl, 0x01 raw out)`. A `hello` handshake carries `protocol` + `features`, evolution is additive-only, and golden fixtures pin the encodings. The protocol is *"not public yet"*. ([rpc/index.md](https://github.com/pvolok/mprocs/blob/main/src/docs/rpc/index.md)) | Yes |
| **tmux / zellij / shpool / zmx / abduco** | A server owns the PTYs. shpool keeps an in-memory vt100 render to redraw on reattach (Linux-first: *"mac currently still has a few tests which don't pass"*). zmx (Zig, Dec 2025) runs one daemon + socket per session and redraws from a libghostty-vt snapshot on reattach. | Yes |
| **Claude Code itself** | The agent-view **supervisor** hosts background sessions (`claude --bg`, `/background`, `claude attach <id>`, `claude agents --json`). *"The supervisor runs each background session's terminal in its own host process."* Idle, unattached processes stop after about an hour, but the conversation is kept. Research preview. | Yes, for background Claude sessions |

**Recommendation: build a `mapod` daemon.**

1. `mapod` owns every PTY, supervised server, port scanner and FS watcher, and the socket API. The Swift UI, the `mapo` CLI and `mapo mcp` are all clients, so the UI is just another client (WezTerm, tmux, dekit and Superset all work this way). This gives Mapo one source of truth for status. Superset's "derive, don't reconcile" plan is a good read on why that matters.
2. Start it on demand: the app or CLI spawns it detached with `setsid` and takes a lockfile via `fs4` 1.1.0 or `fd-lock` 4.0.4. Consider `SMAppService.agent` later (§8).
3. Keep one headless emulator per PTY (§1.4) for snapshot-on-attach and the query APIs.
4. Wire protocol: use dekit-style frames (`u32 len | u8 kind | payload`) with a `hello {protocol, version, features}` handshake and additive-only changes. Put terminal output on a separate stream connection or use credit-based flow control, so output floods never block control RPCs (Superset's bug).
5. Upgrades: detect a stale daemon and hand off (Superset, dekit `runner upgrade`). Advanced option: pass PTY master fds to the new daemon over SCM_RIGHTS (`sendfd` 0.4.5) for zero-loss upgrades.
6. Keep relaunch-restore for reboot or daemon crash. Persist layout, cwd, server definitions, scrollback snapshots and Claude `session_id`s. On restore, respawn shells in their cwd, restart servers per policy, and run `claude --resume <id>` (optionally with `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1`).
7. **Why this matters for this user:** you build Mapo inside Mapo. Without a daemon, every UI rebuild kills the agents and dev servers that are building it.
8. **Renderer coupling (important).** Upstream full libghostty (`ghostty_surface_config_s` has `command`, `working_directory`, `env_vars`) **spawns and owns its own PTY**. A "non-pty termio backend" for host-fed surfaces was proposed in [ghostty#14277](https://github.com/ghostty-org/ghostty/pull/14277) and closed unmerged on 2026-09-20. If the Swift UI uses full libghostty like cmux, you have three choices:
   - Set the surface command to a tiny `mapo attach <tab>` client. This is a tmux-style double PTY hop, and the daemon repaints from its snapshot.
   - Render with SwiftTerm (1.20.0, 2026-08-18; 2.0 with IO-layer changes and a Metal renderer is in progress) fed from the daemon.
   - Build a renderer on libghostty-vt.

   If you don't want any of these, the fallback is cmux-style relaunch-only, with no daemon.

---

## 2. Process and port inspection on macOS

| Crate | Version (date) | Use |
|---|---|---|
| [`libproc`](https://docs.rs/libproc) | 0.14.11 (2025-10-01; repo active 2026-09) | `proc_pid::{pidinfo::<BSDInfo>, pidpath, name, pidcwd, listpidinfo::<ListFDs>}`, `file_info::pidfdinfo::<SocketFDInfo>` (TCP state, local port), `processes::pids_by_type(ProcFilter::{All, ByProgramGroup, ByTTY, ByUID, ByRealUID, ByParentProcess})`. |
| [`listeners`](https://github.com/GyulyVGC/listeners) | 0.6.1 (2026-08-02) | `get_all() -> HashSet<Listener{process{pid,name,path}, socket, protocol, state}>`, `get_process_by_port(port, proto)`. On macOS it walks all pids, then socket fds (`proc_pidfdinfo`), with name/path caches. `get_all` includes ESTABLISHED sockets, so filter `state == Listen`. |
| [`sysinfo`](https://docs.rs/sysinfo) | 0.39.6 (2026-07-09) | `Process::{cwd, parent, start_time, cmd, environ, exe, session_id, user_id}`. Returns `None` when not permitted. Heavier because it refreshes whole tables. |
| [`netstat2`](https://crates.io/crates/netstat2) | 0.11.2 (2025-08-14) | Socket table with pids. Less active. |
| `darwin-libproc` | 0.2.0 (2020) | Stale; avoid. |

- **Port → owner → tab**: scan listening sockets, then map each pid to a tab using (a) tty membership (`ByTTY`) or (b) the ancestor chain up to a PTY child pid or server root pid. cmux does this reactively: shells send `report_tty` + `ports_kick` after commands, the kicks are coalesced for 200 ms, then one `ps -t <ttys>` + `lsof -p <pids>` burst runs ([PortScanner.swift](https://github.com/manaflow-ai/cmux/blob/main/Sources/PortScanner.swift)). Doing it natively in Rust with libproc avoids spawning `ps`/`lsof`.
- **cwd of a process**: prefer OSC 7 from shell integration. Fall back to `pidcwd` (`PROC_PIDVNODEPATHINFO`) on the `tcgetpgrp` leader.
- **Parent**: `pbi_ppid`. **Start time**: `pbi_start_tvsec/usec`. **Controlling tty**: `e_tdev` / `ByTTY`.
- **Permission limits**:
  - `proc_pidinfo` and `proc_pidfdinfo` on **other users'** processes fail without root (EPERM), so you only see your own processes. That's fine for dev servers.
  - Under the **hardened runtime** these calls are unaffected. Hardened runtime restricts debugging, injection, JIT and library loading, not proc_info on your own processes.
  - Under the **App Sandbox**, process-info on non-self processes is denied. That's another reason not to sandbox (§8).
  - Docker-published ports show as `com.docker.backend`/vpnkit, not the container. Never offer to "kill" those.
  - `lsof -nP -iTCP -sTCP:LISTEN -F pcn` parsing remains a fallback.

---

## 3. MCP in Rust

- **Official SDK:** [`rmcp`](https://github.com/modelcontextprotocol/rust-sdk) **3.5.0** (2026-09-28). Majors: 1.0 on 2026-03-03, 2.0 on 2026-06-29, 3.0 on 2026-07-28 (aligned to spec **2026-07-28**). It stays compatible with 2025-11-25 and earlier. The pace is fast, so pin the version and wrap it in a thin module.
- **Feature flags** (from Cargo.toml): `server` (default), `macros` (default), `client`, `transport-io` (stdio), `transport-async-rw` (any AsyncRead/AsyncWrite, **so a Unix stream works too**), `transport-child-process` (uses process-wrap), `transport-streamable-http-server` (Tower service), `transport-streamable-http-client-reqwest`, `transport-streamable-http-client-unix-socket`, `transport-worker`, `elicitation`, `auth`, `request-state` (SEP-2322 MRTR).
- **HTTP semantics:** per SEP-2567, rmcp serves 2026-07-28 **statelessly**: no `Mcp-Session-Id`, no standalone GET/DELETE, no `Last-Event-ID`. `with_legacy_session_mode(false)` makes older revisions stateless too.
- **Tool definition:**

```rust
use rmcp::{handler::server::wrapper::Parameters, schemars, tool, tool_router, ServiceExt, transport::stdio};

#[derive(serde::Deserialize, schemars::JsonSchema)]
struct SendText { tab: String, text: String, enter: Option<bool> }

#[derive(Clone)] struct Mapo { api: DaemonClient }

#[tool_router(server_handler)]
impl Mapo {
    #[tool(description = "Type text into a Mapo tab")]
    async fn send_text(&self, Parameters(p): Parameters<SendText>) -> Result<String, rmcp::ErrorData> { /* call mapod */ }
}
// in `mapo mcp`:
Mapo { api }.serve(stdio()).await?.waiting().await?;
```

- `outputSchema` and `structuredContent` can be any JSON type as of 2026-07-28. `CallToolResult` can mix text, image, audio and embedded resources.

**Reaching Mapo's MCP server from a Claude session inside a tab.** Recommended path:

- **Stdio adapter** in the plugin's `.mcp.json`: `{"mcpServers":{"mapo":{"command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["mcp"]}}}`.
- The stdio child inherits the PTY environment (`MAPO_TAB_ID`, `MAPO_SOCKET`, `MAPO_TOKEN`). Claude Code also sets `CLAUDE_CODE_SESSION_ID` in stdio MCP subprocesses, so the adapter knows both the calling tab and the calling Claude session.
- Implement MCP in the `mapo` binary as a client of the daemon's API, the same way the CLI is. That keeps rmcp's churn out of the daemon.
- Alternative: make `mapo mcp` a dumb pipe and run rmcp inside `mapod` over the Unix stream (`transport-async-rw`).

Why not HTTP (`{"type":"http","url":"http://127.0.0.1:${MAPO_MCP_PORT}/mcp","headers":{"Authorization":"Bearer ${MAPO_TOKEN}"}}`)? It would work, since `${VAR}` expansion is supported in `url`/`headers`. But it exposes a TCP port to every local process, needs port discovery, and Claude Code's idle timeout is **5 min for HTTP/SSE/WS versus 30 min for stdio** (`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`). Long tools like `wait_for_output` or `ask_tab` fit stdio better. They should also emit progress notifications.

Claude Code specifics that affect Mapo's roughly 51 tools:

- Tool search defers MCP tools by default.
- Tool descriptions and server instructions are capped at **2,048 chars** (`CLAUDE_CODE_MAX_MCP_DESCRIPTION_LENGTH`, v2.1.280).
- Output warns at 10k tokens and hard-caps at 25k (`MAX_MCP_OUTPUT_TOKENS`). A tool can raise its own cap with `_meta["anthropic/maxResultSizeChars"]` (up to 500k).
- Calls longer than 2 min auto-background (`CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`).
- Two MCP client runtimes exist. The v2 runtime (TS SDK 2.0, 2026-07-28) is the default only on cloud, Bedrock, Vertex, Foundry and gateway since 2.1.274, so expect older-protocol clients in practice.

---

## 4. CLI ↔ app IPC

**How others do it**

- **cmux**:
  - Transport: Unix socket at `/tmp/cmux.sock` (plus `-debug`, `-nightly` and `-staging` variants), overridable with `CMUX_SOCKET_PATH`.
  - v2 protocol: newline-delimited JSON, `{"id","method","params"}` → `{"ok":true,"result"}` or `{"ok":false,"error":{code,message}}`. v1 was plaintext.
  - Env in every surface: `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_TAB_ID`. Optional `CMUX_SOCKET_PASSWORD`.
  - Access modes: off / **cmux-processes-only** (default) / automation (any same-user process) / password / open.
  - The "cmuxOnly" check reads the peer PID with `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` and walks `sysctl(KERN_PROC_PID).kp_eproc.e_ppid` up to 128 levels looking for the cmux pid. If the peer already exited, it falls back to a `LOCAL_PEERCRED` uid check ([SocketTransport+Peer.swift](https://github.com/manaflow-ai/cmux/blob/main/Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Transport/SocketTransport%2BPeer.swift)).
  - Policy: CLI commands must not steal focus. High-frequency telemetry is handled off the main thread.
  - Wrappers live in `Resources/bin` and go on PATH through shell integration (`ZDOTDIR` `.zshenv` trick, bash bootstrap, fish, nushell).
- **Ghostty**: CLI is `Contents/MacOS/ghostty`. Shell integration appends `$GHOSTTY_BIN_DIR` to PATH when `GHOSTTY_SHELL_FEATURES` contains `path`. macOS automation is **AppleScript** (`OSAScriptingDefinition: Ghostty.sdef`). No control socket.
- **Zed**: CLI is `Zed.app/Contents/MacOS/cli`, installed as a `/usr/local/bin/zed` symlink (it escalates with `osascript` admin if needed). The CLI creates an `ipc-channel` `IpcOneShotServer`, then opens `zed-cli://<server_name>` through LaunchServices (`LSOpenFromURLSpec`), and the app connects back. There's no always-listening socket.
- **VS Code**: `code` is a shell script in `Contents/Resources/app/bin` with an "Install 'code' command in PATH" symlink. Integrated terminals get `VSCODE_IPC_HOOK_CLI`, a per-window Unix socket (HTTP over UDS). Stale env values after reloads cause `ENOENT` errors.
- **Warp**: only a URI scheme (`warp://action/new_tab?path=…`, `warp://launch/<cfg>`). A programmatic tab API for agent hooks is still an open request ([#13895](https://github.com/warpdotdev/warp/issues/13895)).
- **dekit**: framed binary+JSON over a Unix socket, with the address recorded in the runtime dir (see §1.5).
- **Claude Code's own inbox socket**: `/tmp/cc-socks-<uid>` fallback, restricted to your OS user, with an optional `{"type":"auth","token":…}` first line.

**Recommendation for Mapo**

- **Transport**: `tokio::net::UnixListener`. The socket path must stay under **104 bytes** (Darwin `sun_path`). Use `~/.mapo/run/mapod.sock` (no spaces) or `~/Library/Application Support/Mapo/run/…` after a length check. Create the directory 0700 and the socket 0600. If you ever use `/tmp`, verify the owner and mode of the directory first, as Claude Code does.
- **Framing**:
  - UI ↔ daemon: dekit-style `u32 len | u8 kind | payload`.
  - CLI, hooks and scripts: plain **newline-delimited JSON-RPC 2.0**, which is easy from bash, Swift and Rust.
  - `tokio_util::codec::{LinesCodec, LengthDelimitedCodec}` covers both.
  - `jsonrpsee` 0.26 is HTTP/WS-centric. `tarpc` 0.38 has Unix transports but only Rust peers can use it, so hooks and Swift couldn't talk to it.
- **Auth**:
  - Socket perms, plus `UnixStream::peer_cred()` (tokio `UCred` gives uid, gid and **pid on macOS**) to check the uid.
  - Optional cmux-style ancestry check for a "strict" mode.
  - Per-tab `MAPO_TOKEN` (random 128-bit) and `MAPO_TAB_ID` in each PTY's environment. The CLI sends them in `hello`, so commands default to "this tab", and you can scope or revoke capabilities per tab.
  - Be honest about what this protects: any same-user process can read another same-user process's environment, so the real security boundary is the Unix user. Tokens prevent accidents and let you scope and audit.
  - Use a **stable socket path**, not per-instance paths, so long-lived shells don't end up with stale env after restarts (the VS Code failure mode).
- **Shipping the CLI**:
  - Put the Mach-O at `Contents/MacOS/mapo` or `Contents/Helpers/mapo`. Code belongs there. Signed code under `Contents/Resources` tends to cause codesign and notarization pain. Scripts are fine as resources.
  - Add a `Contents/Resources/bin/` directory holding only a `mapo` symlink, and prepend it to each PTY's `PATH`.
  - macOS `/etc/zprofile` runs `path_helper`, which moves inherited entries **after** the system dirs. That's harmless for a uniquely named `mapo`, and it only mattered for cmux's `claude` shim, which Mapo doesn't need (§5).
  - Offer "Install CLI" to create a `/usr/local/bin/mapo` or `~/.local/bin/mapo` symlink.
  - Rust CLI startup is a few ms, so running one exec per hook event is fine. cmux built a zsh spool-and-forwarder for hooks, likely because of Swift CLI startup cost (my inference).

---

## 5. Claude Code integration

### 5.1 Hook events (CLI 2.1.284, [hooks reference](https://code.claude.com/docs/en/hooks))

`SessionStart` (matcher: `startup|resume|clear|compact|fork`), `Setup`, `UserPromptSubmit`, `UserPromptExpansion`, `PreToolUse`, `PermissionRequest`, `PermissionDenied`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `Notification` (matchers: `permission_prompt, idle_prompt, auth_success, elicitation_dialog, elicitation_url_dialog, elicitation_complete, elicitation_response, agent_needs_input, agent_completed, quota_auto_resume_*`), `MessageDisplay`, `SubagentStart`, `SubagentStop`, `TaskCreated`, `TaskCompleted`, `Stop`, `StopFailure` (matchers: `rate_limit|authentication_failed|server_error…`), `TeammateIdle`, `InstructionsLoaded`, `ConfigChange`, `CwdChanged`, `DirectoryAdded`, `FileChanged`, `WorktreeCreate`, `WorktreeRemove`, `PreCompact`, `PostCompact`, `PreModelSwitch`, `PostModelSwitch`, `Elicitation`, `ElicitationResult`, `SessionEnd` (reasons: `clear|resume|logout|prompt_input_exit|other`).

- **Handler types**: `command` (with `args` for exec form without a shell, plus `async`/`asyncRewake`), `http` (POST JSON; headers can interpolate only env vars listed in `allowedEnvVars`, and a user or org `allowedHttpHookUrls` allowlist can block it), `mcp_tool` (skipped on the launch `SessionStart`), `prompt`, `agent`.
- **Common input fields**: `session_id`, `prompt_id` (v2.1.196+), `transcript_path`, `cwd`, `permission_mode`, `effort`, `hook_event_name`, `agent_id/agent_type` for subagents.
- **`Stop` and `SubagentStop` include `last_assistant_message`.** The docs say to use it instead of reading the transcript, which *"may lag"*. This is how "ask another tab and get its reply" works.
- **`Stop` does not fire on a user interrupt** (Esc/Ctrl-C). Superset synthesizes a `Stop` when an interrupt key passes through, and Mapo needs to do the same.
- Hooks get `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN` in their environment. `SessionStart`/`Setup`/`CwdChanged`/`FileChanged` hooks also get `CLAUDE_ENV_FILE`.
- The `SessionEnd` budget is only 1.5 s in total.

### 5.2 Injecting Mapo without editing user settings (best to worst)

1. **`CLAUDE_CODE_PLUGIN_DIRS`**:
   - Colon-separated plugin dirs, *"each loaded the way a `--plugin-dir` flag loads it"*. Absolute paths only. **Requires v2.1.280**, released 2026-09-22 ([env-vars](https://code.claude.com/docs/en/env-vars)).
   - Set it in every Mapo PTY's environment, appending to any value the user already has. Then **every** `claude` started in a Mapo tab loads the Mapo plugin, whether typed by hand or run through other wrappers.
   - No PATH shim, no settings edits, no `--settings` merge problems.
   - The plugin contains `hooks/hooks.json` (lifecycle → `mapo hook`), `.mcp.json` (the `mapo mcp` stdio server), and `skills/mapo/SKILL.md` (teaches Claude the CLI and tools).
   - A plugin's `settings` only honors `agent` and `subagentStatusLine`, so it **can't set `statusLine`**.
   - Plugin MCP tools are named `mcp__plugin_<plugin>_<server>__<tool>`.
2. **`--plugin-dir <path>`** (repeatable) for tabs Mapo launches itself. Use this as the fallback on CLIs older than 2.1.280.
3. **cmux's approach**: a PATH `claude` shim (`Resources/bin/cmux-claude-wrapper`, **2,345 lines of bash**) that injects `--session-id <uuid>` plus one merged `--settings` file. Their source documents two traps:
   - *"with two `--settings` on the command line Claude Code reads only ONE of them… first-wins on <=2.1.168… last-wins on >=2.1.169"*. So if you use `--settings`, deep-merge everything into one file.
   - The shim must defeat re-exec loops with other shims.

   cmux also sets `preferredNotifChannel` so its hooks are the only notification source.
4. Writing hooks into `~/.claude/settings.json`, guarded by `[ -n "$MAPO_TAB_ID" ]`. cmux does this only for sessions started outside its shells. It's the most robust against CLI changes, but it edits user settings.

`--settings` precedence sits above user, project and local settings and below managed settings. Lists such as hook arrays and permissions merge across levels.

**Hook command sketch (plugin `hooks/hooks.json`):**

```json
{"hooks":{
  "SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"],"timeout":5}]}],
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"],"async":true}]}],
  "PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"],"async":true}]}],
  "PermissionRequest":[{"matcher":"","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"],"async":true}]}],
  "Notification":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"]}]}],
  "Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"]}]}],
  "StopFailure":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"]}]}],
  "SubagentStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"],"async":true}]}],
  "SubagentStop":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"],"async":true}]}],
  "SessionEnd":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/mapo","args":["hook"],"timeout":1}]}]
}}
```

`mapo hook` reads stdin JSON, adds `MAPO_TAB_ID`, `MAPO_TOKEN` and the parent pid, forwards to `mapod`, prints `{}`, and exits 0. Outside Mapo it's a no-op. Keep `PermissionRequest` synchronous only if the Mapo UI will answer permissions, the way cmux's "Feed" does (synchronous, 125 s timeout).

**Status state machine** (pure function of the last event, per Superset's "derive, don't reconcile"):

- `SessionStart` → idle (record `session_id`, `transcript_path`)
- `UserPromptSubmit` → running (record `prompt_id`)
- `PreToolUse` → running. Special case: `AskUserQuestion` or `ExitPlanMode` → needs input. Under `bypassPermissions`, no `PermissionRequest` fires (cmux issue #6606).
- `PermissionRequest` or `Notification(permission_prompt | elicitation_* | agent_needs_input)` → needs input
- `Notification(idle_prompt)` → idle
- `Stop` → done, unread (keep `last_assistant_message`)
- `StopFailure` → error
- A passed-through interrupt → idle, synthesized
- `SessionEnd` → exited

### 5.3 Other channels

- **Status line**: runs on each new assistant message, `/compact`, mode change and so on, debounced at 300 ms, with an optional `refreshInterval`. The stdin JSON includes `model`, `workspace` (including `git_worktree`), `cost`, `context_window.used_percentage`, `rate_limits.{five_hour,seven_day}`, `prompt_cache`, `worktree` and more. You can only inject it through `--settings`, and doing so **replaces** the user's `statusLine`. Workaround: Mapo's statusline command runs the user's own command, prints its output, and tees the JSON to `mapod`.
- **`claude agents --json`**: *"the supported way to read session state from outside Claude Code"*. Fields: `kind`, `id`, `state`, `pid`, `status: busy|waiting|idle`, `waitingFor`, `sessionId`, `name`. Interactive sessions only appear **after they're backgrounded**. `claude --bg` + `claude attach <id>` inside a Mapo PTY gives Claude-native persistence. Research preview.
- **Cross-session messaging** (v2.1.224+): each session binds an inbox Unix socket (`CLAUDE_CODE_MESSAGING_SOCKET`, token in `CLAUDE_CODE_MESSAGING_TOKEN`). Scripts can post to it. Messages from outside are marked "from another session, not you", can't approve permissions, and follow `crossSessionInbound` (`accept|hold|refuse`). Messages to a session in bypass mode are held by default. **The wire schema beyond the auth line isn't documented; verify before relying on it.**
- **Channels** (`--channels`, research preview): MCP servers push events into a running session. During the preview they need allowlisted plugins or `--dangerously-load-development-channels`. Not a good fit for Mapo.
- **OpenTelemetry**: `CLAUDE_CODE_ENABLE_TELEMETRY=1` plus OTLP env gives metrics, events and traces. It's optional, and it clashes if the user already exports to their own collector.

### 5.4 Headless / Agent SDK versus a PTY-wrapped TUI

- **Agent SDK**: official only for **TypeScript and Python**. For other languages the docs say to *"run the CLI as a subprocess with `-p`"*.
  - Useful flags: `claude -p --input-format stream-json --output-format stream-json --verbose [--include-partial-messages --include-hook-events --forward-subagent-text --replay-user-messages]`. The first event is `system/init` (it carries a `capabilities` array for feature detection), the last is a `result` message. Permissions go through `--permission-prompt-tool` (an MCP tool) or `--permission-prompts none`.
  - Unofficial Rust crates: `claude-codes` 2.1.285 (typed stream-json models that track the CLI version), `claude-agent-sdk-rs` 0.6.4, `cc-sdk` 0.8.1. **Trap:** `claude-agent-sdk` 0.1.1 on crates.io points at a non-existent `anthropics/claude-agent-sdk-rust` repo and is owned by an individual. It is **not official**.
  - Policy: *"Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK."* A personal app running your own login is fine. It matters if Mapo is ever distributed.
- **Conductor** (Mac, Tauri) runs Claude Code through the SDK with its own chat UI (per third-party write-ups; not verified from source). **cmux** and **Superset** wrap the interactive CLI in PTYs and use hooks.
- **Recommendation**:
  - Keep **interactive TUI in a PTY + plugin hooks + MCP** for human-facing Claude tabs. You get full UX parity with no chat UI to rebuild, and it's exactly how the user runs Claude today.
  - Use `claude -p … --output-format stream-json` only for Mapo-internal automations, such as auto-naming, summaries, or a side query with `--resume <id> --fork-session` that reads a session's context without disturbing it.
  - "Ask another tab":
    1. Wait until the target is idle.
    2. Type the prompt with bracketed paste + CR, or post to its inbox socket once the schema is verified.
    3. Correlate on `UserPromptSubmit.prompt_id`.
    4. Return `Stop.last_assistant_message`.

---

## 6. File system and git

- **[`notify`](https://github.com/notify-rs/notify)**:
  - Versions: 8.2.0 stable (2025-08-03). **9.0.0-rc.5 (2026-08-30)** moved FSEvents to `objc2-core-services`, added `Config::with_fsevent_latency`, coalesces nested recursive watches into one stream, stopped FSEvents-callback panics, and adds `Watcher::update_paths` and `watched_paths`. MSRV 1.88.
  - Backend: FSEvents by default on macOS; kqueue via `macos_kqueue`. Caveats: coalescing, rename ambiguity, variable latency.
  - Debouncers: `notify-debouncer-full` 0.7.0 (0.8.0-rc.2) does rename stitching and file-ID caching. `notify-debouncer-mini` 0.7.0 is the minimal one.
  - Zed pins a fork of notify.
  - Suggestion: one recursive watch per workspace root, a 100–300 ms debounce, filter through `ignore`, and treat `.git/{HEAD,index,refs/**}` events as a git refresh trigger.
- **[`ignore`](https://docs.rs/ignore)** 0.4.33 (2026-08-04):
  - Explorer: `WalkBuilder::new(dir).max_depth(Some(1)).parents(true).git_ignore(true).git_exclude(true).git_global(true)` for lazy per-folder listing.
  - Fuzzy index: `build_parallel()`.
- **Fuzzy**: [`nucleo`](https://github.com/helix-editor/nucleo) 0.5.0 (released 2024-04, repo active 2026-06). It uses a background threadpool with an `Injector`, so you stream paths from the parallel walker. Helix and Zed use it. `nucleo-matcher` 0.3.1 is the low-level matcher. Alternatives: `frizbee`/`neo_frizbee` 0.13.x (SIMD Smith-Waterman, active 2026-09).
- **Git**:
  - **Zed has no git2 or gix dependency today.** It shells out: `git status --porcelain=v1 --untracked-files=all --no-renames -z`, `git worktree list --porcelain`. Every call gets `-c core.fsmonitor=false` (*"to stop malicious actors from running arbitrary commands via fsmonitor hooks"*), `-c log.showSignature=false`, `--no-optional-locks` and `--no-pager`, plus `-c core.hooksPath=/dev/null` for untrusted repos ([repository.rs](https://github.com/zed-industries/zed/blob/main/crates/git/src/repository.rs)).
  - **`gix` 0.88.0** (2026-09-25; `gix-status` 0.35, `gix-dir` 0.30):
    - Supported: status (index↔worktree, index↔index), blob and tree diffs (imara-diff), worktree open and create, per-worktree config.
    - **Missing**: fsmonitor, untracked-cache, split-index and sparse-index acceleration; SHA-256 and reftable; worktree move/remove/repair; checkout/stash.
    - It's good for cheap, spawn-free reads: `gix::discover(cwd)`, HEAD and branch name, linked-worktree detection, upstream, ahead/behind. It never executes fsmonitor hooks.
  - **`git2`** 0.21.0 (2026-05-18) is mature, but brings a libgit2 C dependency and lags new git features.
  - **Pick**: `gix` for discovery, branch and worktree reads. The `git` CLI (hardened with Zed's flags) for status decorations and diffs. `imara-diff` 0.2.0 or `similar` 3.2.0 for in-app hunk computation.

---

## 7. mprocs, dekit and process-compose

- **mprocs is now dekit.** [pvolok/mprocs](https://github.com/pvolok/mprocs) published **v0.10.0 as "dekit"** on 2026-09-28. It's a process manager "for dev and prod" with:
  - a separate **runner** process that outlives the terminal (`dekit up/ls/attach/down`), plus an optional host runner (`~/.config/dekit/host/dekit.yaml`)
  - a CLI with JSON output built for agents: `dekit ls --json` → `{"tasks":[{id,path,label?,state,exit_code?,signal?,reason?}]}`, `dekit why`, `dekit screen <task> --json` (current screen as ANSI), `run` and `spawn`
  - built-in JavaScript scripting
  - `dekit mprocs` still runs an `mprocs.yaml` unchanged and answers `--ctl`
- **Reading an mprocs.yaml**:
  - Schema: [`schemas/mprocs.json`](https://github.com/pvolok/mprocs/blob/main/schemas/mprocs.json). Top level: `procs`, `server`, `hide_keymap_window`, `mouse_scroll_speed`, `scrollback`, `proc_list_width`, `proc_list_title`, `proc_log`, `on_all_finished`, `keymap_*`.
  - A proc is a string (shell shorthand), an array (argv), `null` (disabled), or an object with `shell|cmd`, `cwd` (`<CONFIG_DIR>` prefix), `env` (null unsets), `add_path`, `autostart` (default true), `autorestart` (bool; no restart if it exits within 1 s), `stop` (`SIGINT|SIGTERM|SIGKILL|hard-kill|{send-keys}|{cmd}`), `deps`, `log`.
  - `$select: os` / `$else` operators pick per-OS values.
  - Config is loaded from `~/.config/mprocs/mprocs.yaml` (global) and `./mprocs.yaml`.
  - Old remote control: `server: 127.0.0.1:4050` + `mprocs --ctl '{c: restart-proc}'` (YAML commands over TCP).
  - YAML crates: `serde_yaml` 0.9.34 is deprecated (dekit still uses it). Maintained options are `serde-saphyr` 1.3.0 and `yaml-rust2` 0.13.0. **Avoid `serde_yml`**, which is now marked "DEPRECATED — unmaintained".
- **Embed or drive?** Don't embed either one. Mapo already supervises processes itself.
  - Import `mprocs.yaml` or `dekit.yaml` into Mapo server tabs. Map `autorestart:true` → `on-failure` and `shell` → `sh -c`, and respect `deps`, `stop`, `add_path` and `env`.
  - Optionally "attach" to a running dekit runner through its CLI (`dekit ls --json`, `dekit screen`). Its RPC is explicitly *"not public yet and may still change"*.
- **process-compose** (Go) v1.122.0 (2026-08-17):
  - REST API with OpenAPI, default port 8080, **or a Unix socket**: `-U` auto (`<TempDir>/process-compose-<pid>.sock`), `--unix-socket <path>`, or `PC_SOCKET_PATH`.
  - Token auth via `PC_API_TOKEN` (min 20 chars) in the `X-PC-Token-Key` header.
  - CLI: `process list|start|stop|restart`, `process monitor -o json` (over WebSocket).
  - Drive it through the socket if a project uses it. Don't embed.

---

## 8. macOS integration from the Swift app

- **Sandbox**: ship **unsandboxed** (Developer ID + notarized, hardened runtime). Ghostty's and cmux's entitlements files contain no `com.apple.security.app-sandbox`. Reasons:
  - *"Child processes always inherit their sandbox from their parent"* (Apple DTS). A sandboxed terminal would sandbox every shell and tool.
  - `NSWorkspace.setDefaultApplication` fails in the sandbox with `permErr -54` (Quinn, [forum 731555](https://developer.apple.com/forums/thread/731555)).
  - Cross-process `proc_pidinfo` is denied.
  - Mac App Store distribution is effectively out.
- **Hardened runtime gotcha (TCC attribution)**:
  - Tools run in the terminal are attributed to the **responsible process**, which is the terminal app. If the app lacks the entitlement, *"tccd decides … the app is not eligible to ask, so it never shows a dialog."*
  - Ghostty ships `com.apple.security.device.{camera,audio-input}`, `personal-information.{addressbook,calendars,location,photos-library}` and `automation.apple-events`. cmux ships a subset; mic was requested in cmux#1325. VS Code is adding the missing `NS*UsageDescription` keys ([vscode#307364](https://github.com/microsoft/vscode/issues/307364)).
  - Mapo needs **both** the entitlements and the Info.plist usage strings.
  - Ghostty rejected using the `responsibility_spawnattrs_setdisclaim` SPI because it would push TCC grants down to shells ([#9263](https://github.com/ghostty-org/ghostty/issues/9263)).
  - If `mapod` spawns the shells, check **which process macOS treats as responsible** for them. The daemon binary may need the same entitlements plus an embedded Info.plist (`-sectcreate __TEXT __info_plist`). **Unverified.**
- **Default opener**:
  - Declare `CFBundleDocumentTypes` with `LSItemContentTypes` (`public.source-code`, `public.plain-text`, `public.script`, `public.shell-script`, `public.json`, `public.yaml` (macOS 14+), `net.daringfireball.markdown`), `CFBundleTypeRole` Editor and **`LSHandlerRank` Alternate**.
  - Warp issue [#13268](https://github.com/warpdotdev/warp/issues/13268): a UTI-level claim won `.md` "even at `LSHandlerRank Alternate`" and kept reclaiming it after updates, so the Markdown type was removed ([#15218](https://github.com/warpdotdev/warp/pull/15218)). Only claim what you mean.
  - Offer an explicit "Make Mapo the default for…" button that calls `NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: UTType)` (macOS 12+). Apple: *"If a change requires user consent, the system asks the user for consent asynchronously before invoking the completion handler."* Handle files in `application(_:open:)`.
  - Ghostty claims `public.directory` (Alternate) and `public.unix-executable` (role Shell), and offers "New Ghostty Tab/Window Here" `NSServices`.
- **Notifications**:
  - `UNUserNotificationCenter` in the Swift app, with `UNNotificationCategory` actions such as "Focus tab", "Approve", and a `UNTextInputNotificationAction` to reply to Claude straight from the banner.
  - **Only bundled apps can post.** `UNUserNotificationCenter.current()` throws *"bundleProxyForCurrentProcess is nil"* in bare binaries and LaunchAgents. A bare-Mach-O `mapod` must ask the app to post, launch it in the background, or be shipped as a helper `.app` (for example under `Contents/Library/LoginItems`).
  - Rust crates exist: `objc2-user-notifications` 0.3.2, `mac-usernotifications`. Doing this in Swift is simpler.
- **Dock badge**: `NSApp.dockTile.badgeLabel = "\(needsInputCount)"`. Superset and cmux both badge "needs attention". `NSDockTilePlugIn` (Ghostty ships one) updates the icon while the app isn't running.
- **Global hotkeys**: `sindresorhus/KeyboardShortcuts` (Carbon `RegisterEventHotKey`) needs **no Accessibility permission** and works sandboxed. `NSEvent.addGlobalMonitorForEvents` needs Accessibility. Known macOS 15 bug: combos using only Option or Option+Shift as modifiers don't fire (FB15168205).
- **Login items and background daemon**:
  - `SMAppService.mainApp.register()` (macOS 13+) for "open at login".
  - For a launchd-managed daemon: `SMAppService.agent(plistName:)` with the plist in `Contents/Library/LaunchAgents` and a `BundleProgram` path relative to the bundle. It appears under System Settings › Login Items (Allow in Background), and `status` can be `.requiresApproval`.
  - Starting the daemon on demand without launchd is simpler, and it's what tmux, WezTerm, zellij, Superset and dekit do.
- **Shell integration** (for OSC 7/133 and PATH):
  - Launch zsh with `ZDOTDIR` pointing at bundled `.zshenv`/`.zshrc` shims that source the user's files and then add Mapo hooks. This is Ghostty's and cmux's technique.
  - bash via `--rcfile` or `ENV`; fish via `XDG_DATA_DIRS` vendor conf.
  - Set `TERM_PROGRAM=Mapo` and `COLORTERM=truecolor`.

---

## 9. Risks and things I could not verify

**Risks**

1. **Claude Code churn.** 2.1.224 shipped 2026-08-07 and 2.1.284 shipped 2026-09-28; flags and hook schemas move weekly. Pin a minimum version, feature-detect (`claude --version`, `system/init.capabilities`), and parse hooks leniently. `CLAUDE_CODE_PLUGIN_DIRS` is **6 days old**. Agent view, cross-session messaging and channels are new or in research preview.
2. **rmcp API churn**: three majors between March and July 2026. Pin it and isolate it.
3. **Renderer and PTY ownership conflict**: full libghostty surfaces own their PTYs, and the libghostty APIs are pre-1.0. This decides daemon vs relaunch (§1.5).
4. **Daemon complexity**: protocol versioning, stale-daemon handoff, head-of-line blocking, notifications needing a bundle, TCC attribution for daemon-spawned children, and a daemon crash taking every session down. Mitigations: keep the daemon small, add fd-passing upgrades later, and fall back to relaunch-restore.
5. **Port and process visibility**: same-user only; Docker shows its proxy process; PID reuse (use `(pid, start_time)`).
6. **FSEvents coalescing and latency**. gix has no fsmonitor or untracked-cache acceleration for huge repos. The `git` CLI can run repo-configured commands (`core.fsmonitor`, hooks), so use Zed's hardening flags.
7. **Default-app claims** can hijack user associations (the Warp `.md` case).
8. **Agent SDK / headless policy**: a concern only if Mapo is ever distributed.

**Not verified (read docs or source only; not tested)**

- Real-world behavior of `CLAUDE_CODE_PLUGIN_DIRS`: trust prompts, interaction with the user's own `--plugin-dir`, and whether plugin hooks and MCP run in every mode.
- The wire schema for posting messages into `CLAUDE_CODE_MESSAGING_SOCKET` beyond the `{"type":"auth","token":…}` line.
- Whether the `libghostty-vt` Rust crate exposes a VT/text snapshot formatter (zmx uses one from the Zig API).
- SwiftTerm 2.0 status (not tagged yet; 1.20.0 is described as "one last before 2.0").
- `SMAppService.agent` approval UX, and TCC responsibility for children of a daemon spawned by the app.
- Conductor's internals (third-party write-ups say TypeScript SDK + Tauri).
- The cmux Mintlify docs (manaflow-ai-cmux.mintlify.app) look stale or unofficial. For example, they mention `~/.claude/hooks.json`. I relied on cmux source and `docs/` instead.
- The "Stop not firing on interrupt" workaround comes from Superset's plans and the Claude docs line *"Does not run if the stoppage occurred due to a user interrupt"*.

---

## Sources

- Claude Code docs: [hooks](https://code.claude.com/docs/en/hooks), [cli-reference](https://code.claude.com/docs/en/cli-reference), [env-vars](https://code.claude.com/docs/en/env-vars), [settings](https://code.claude.com/docs/en/settings), [settings-reference](https://code.claude.com/docs/en/settings-reference), [statusline](https://code.claude.com/docs/en/statusline), [headless](https://code.claude.com/docs/en/headless), [agent-sdk overview](https://code.claude.com/docs/en/agent-sdk/overview), [agent-view](https://code.claude.com/docs/en/agent-view), [cross-session-messaging](https://code.claude.com/docs/en/cross-session-messaging), [channels](https://code.claude.com/docs/en/channels), [mcp](https://code.claude.com/docs/en/mcp), [plugins-reference](https://code.claude.com/docs/en/plugins-reference), [monitoring-usage](https://code.claude.com/docs/en/monitoring-usage), [CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)
- cmux: [repo](https://github.com/manaflow-ai/cmux), [claude wrapper](https://github.com/manaflow-ai/cmux/blob/main/Resources/bin/cmux-claude-wrapper), [agent-hooks.md](https://github.com/manaflow-ai/cmux/blob/main/docs/agent-hooks.md), [cli-contract.md](https://github.com/manaflow-ai/cmux/blob/main/docs/cli-contract.md), [session restore](https://cmux.com/docs/session-restore), [issue #2140](https://github.com/manaflow-ai/cmux/issues/2140)
- Superset: [terminal host plan](https://github.com/superset-sh/superset/blob/main/apps/desktop/plans/done/20260106-1800-terminal-host-control-stream-sockets.md), [agent status plan](https://github.com/superset-sh/superset/blob/main/apps/desktop/plans/done/20260703-1507-derive-terminal-agent-status-from-host-binding.md)
- dekit/mprocs: [repo](https://github.com/pvolok/mprocs), [RPC docs](https://github.com/pvolok/mprocs/blob/main/src/docs/rpc/index.md), [agents doc](https://github.com/pvolok/mprocs/blob/main/src/docs/start/agents.md); process-compose: [client docs](https://f1bonacc1.github.io/process-compose/client/)
- Ghostty: [ghostty.h](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h), [PR #14277](https://github.com/ghostty-org/ghostty/pull/14277), [issue #9263](https://github.com/ghostty-org/ghostty/issues/9263), [ghostling](https://github.com/ghostty-org/ghostling), [libghostty-rs](https://github.com/uzaaft/libghostty-rs); zmx: [post](https://bower.sh/zmx-session-persistence); shpool: [repo](https://github.com/shell-pool/shpool)
- Zed: [persistent terminal RFC](https://github.com/zed-industries/zed/discussions/50584), [git repository.rs](https://github.com/zed-industries/zed/blob/main/crates/git/src/repository.rs); WezTerm: [multiplexing](https://wezterm.org/multiplexing.html); Warp: [session restoration](https://docs.warp.dev/terminal/sessions/session-restoration/), [issue #13268](https://github.com/warpdotdev/warp/issues/13268)
- Crates: [rmcp](https://github.com/modelcontextprotocol/rust-sdk), [pty-process](https://docs.rs/pty-process), [portable-pty](https://docs.rs/portable-pty), [process-wrap](https://docs.rs/process-wrap), [libproc](https://docs.rs/libproc), [listeners](https://github.com/GyulyVGC/listeners), [sysinfo](https://docs.rs/sysinfo), [notify](https://github.com/notify-rs/notify), [ignore](https://docs.rs/ignore), [nucleo](https://github.com/helix-editor/nucleo), [gitoxide crate-status](https://github.com/GitoxideLabs/gitoxide/blob/main/crate-status.md), [tokio UCred](https://docs.rs/tokio/latest/tokio/net/unix/struct.UCred.html)
- Apple: [setDefaultApplication](https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopen:completion:)), [forum 731555](https://developer.apple.com/forums/thread/731555), [SMAppService.agent](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), [VS Code TCC issue](https://github.com/microsoft/vscode/issues/307364)
