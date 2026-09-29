# Research, 2026-09-28

Three parallel research passes ran before the interview's architecture questions. The findings drove [DECISIONS.md](../DECISIONS.md) and [ARCHITECTURE.md](../ARCHITECTURE.md). Versions and project statuses are as of 2026-09-28; verify them before pinning.

| File | Question | Headline findings |
|---|---|---|
| [interop-build.md](interop-build.md) | How to join a Rust core and a Swift UI, and how to build, sign and ship | UniFFI 0.32.2 is the default FFI but has Swift 6 gaps and slow record lifting (moot for Mapo, which uses a socket protocol). Build arm64 only. XcodeGen plus a local SwiftPM package plus a justfile follows the `hewigovens/jayjay` blueprint. AppKit owns windows, splits, lists and focus; SwiftUI only for islands (cmux replaced its SwiftUI sidebar after CPU livelocks). Module-map collision risk with GhosttyKit (swift-build #1746). |
| [domain-apps.md](domain-apps.md) | What cmux, Ghostty, Supacode, Superset, Conductor and others do; terminal engines; editors | Every serious native agent terminal embeds libghostty. Upstream surfaces own their PTY, so a daemon needs an attach hop, or a fork with host-managed IO (cmux fork, `Lakr233/libghostty-spm` patch 0002). `libghostty-spm` ships a prebuilt GhosttyKit.xcframework weekly (MIT). Superset's PTY daemon is the best checklist: handshake, 0600 socket, framing, ring buffer, FD handoff. Native editor components are thin (STTextView is GPL, CodeEditSourceEditor isn't production-ready). |
| [core-crates.md](core-crates.md) | Rust crates for PTY, processes/ports, MCP, IPC, git and fs; Claude Code integration; macOS integration | pty-process 0.5.3 (async) plus rustix; alacritty_terminal 0.26 as the headless emulator plus vte for OSC 7/133; libproc and listeners for ports; rmcp 3.5.0 (pin exactly); hand-rolled NDJSON over a Unix socket; notify, ignore, and the git CLI with Zed's hardening flags. `CLAUDE_CODE_PLUGIN_DIRS` (CLI 2.1.280+) injects hooks, MCP and skill with no settings edits. Stop doesn't fire on Esc. `last_assistant_message` on Stop enables `tab ask` without scraping. Ship unsandboxed with the hardened runtime and usage strings. |

Decisions that went against a research recommendation:

- **Editor.** The research recommended Monaco in a WKWebView. The user chose a native TextKit 2 editor to keep the app native and light, given the limited editing scope (see DECISIONS D-14).
- **Terminal I/O.** The research leaned toward Rust-owned PTYs fed into libghostty through a fork. The user chose upstream libghostty plus `mapo attach`, with no fork (D-13). The `TerminalSurface` protocol keeps the fork path open.
