# Mapo native rewrite: domain reference apps and components

Research date 2026-09-28. Star counts, versions and dates come from the GitHub, crates.io and npm APIs on that day unless a line says otherwise. Things I could not confirm are collected in section 7.

## Short version

- Terminal engine: embed full libghostty, the `ghostty.h` embedding API that Ghostty's own macOS app uses, one NSView per terminal. This is what cmux, Supacode, agterm, Calyx, Muxy, Factory Floor, Zentty and OrbStack ship. It gives Metal rendering, IME, VoiceOver text, kitty keyboard and kitty graphics, and it already turns OSC 7, OSC 9/777, OSC 9;4, OSC 133 and BEL into typed callbacks that line up with Mapo's features. The catch is that upstream now labels that header "libghostty-internal" with no stability promise. Pin a commit and put it behind a small Swift protocol.
- Process ownership: upstream libghostty spawns and owns the PTY itself. If the Rust core should own long-lived processes (server tabs, restart policies, survive app restarts), make the Ghostty surface run a tiny attach client (`mapo attach <id>`) that talks to a Rust PTY daemon. That is the zmx/tmux pattern Supacode, agterm, Factory Floor and cmux use, and it needs no Ghostty patches.
- Editor: Monaco in one long-lived WKWebView for editing and diffs, assets served through a custom URL scheme, git gutter hunks computed in Rust with gix + imara-diff (Helix does exactly this). Factory Floor, a native Ghostty-based agent workspace, ships Monaco in WKWebView. cmux, the most polished native app here, renders its diff viewer as a web view too. Native Swift editors exist, but none has a usable diff view.
- Fallback terminal: SwiftTerm. MIT, pure Swift, drop-in NSView, accepts bytes from any source without patches. Weaker renderer.

## 1. cmux (manaflow-ai/cmux)

### Facts

- Repo: <https://github.com/manaflow-ai/cmux>. 27.5k stars, 2.4k forks, about 18.4k commits and 205 contributors. GitHub says created 2026-01-28 and it is pushed daily. Latest stable release v0.64.25 on 2026-09-17, plus nightly and rc channels. Sparkle auto-update and a Homebrew cask.
- Stack: Swift and AppKit with some SwiftUI, macOS only, with an iOS companion in TestFlight. By bytes: Swift 94 MB, Rust 19 MB, TypeScript 14 MB, Python 13 MB (mostly tests), Zig from the ghostty submodule.
- License history from the LICENSE file log: AGPL-3.0 in February 2026, dual AGPL plus commercial on 2026-03-24, relicensed to GPL-3.0-or-later on 2026-03-30, and on 2026-09-28 the server directories (`web/`, `workers/*`, relay services) moved to BUSL-1.1. The app, CLI and cmux-tui are GPL-3.0-or-later. Reading it for ideas is fine. Copying code into Mapo would make Mapo GPL.

### Features

Vertical sidebar of workspaces. Each row shows git branch, linked PR status and number, working directory, listening ports and the latest notification text. Horizontal and vertical splits, Cmd+1..8 to jump workspaces. Blue notification rings around panes that want attention, a notification panel, Cmd+Shift+U jumps to the latest unread. A browser pane (WKWebView) with a scriptable API ported from agent-browser: navigate, DOM and accessibility snapshots, click, type, evaluate JS, network monitoring, cookie import from 20+ browsers. A "Feed" for inline permission approvals from the sidebar. Session restore of layout, cwds, scrollback (best effort) and browser history, and `cmux local-tmux` for live process persistence. SSH workspaces. Claude Code "teams" mode that spawns teammates as native panes. Custom commands in `~/.config/cmux/cmux.json`.

### How it embeds libghostty

- The `ghostty` submodule points at the fork `manaflow-ai/ghostty`. A CI workflow (`build-ghosttykit.yml`) builds `GhosttyKit.xcframework` with Zig 0.16.0 and publishes it as a release on the fork, keyed by Ghostty commit SHA. `scripts/ghosttykit-checksums.txt` pins the SHA-256.
- `docs/ghostty-fork.md` (116 KB) documents about 40 fork patches. Examples: a mutex around the embedded surface registry because an off-main `ghostty_surface_free` could race main-thread `ghostty_surface_new`. Synchronous teardown so no callback fires after `ghostty_surface_free` returns. Frame pacing that caps unfocused surfaces near 30 fps, to cut WindowServer compositing when many agents stream into background panes. Host-managed IO for iOS. An external Metal presenter for cloud terminals. Hangul and CJK font fixes, atomic bracketed paste, Cmd-click links under mouse reporting, bounded kitty graphics state.
- `Sources/GhosttyTerminalView.swift` is 14,597 lines. It calls `ghostty_app_new`, `ghostty_surface_new`, the key, text, preedit, mouse and IME functions, and handles 30+ `GHOSTTY_ACTION_*` cases including PWD, SET_TITLE, DESKTOP_NOTIFICATION, RING_BELL, COLOR_CHANGE, CONFIG_CHANGE, OPEN_URL, MOUSE_OVER_LINK, NEW_SPLIT, GOTO_SPLIT, START_SEARCH, SECURE_INPUT, SHOW_CHILD_EXITED and SCROLLBAR. Ghostty's own equivalent view, `SurfaceView_AppKit.swift`, is 2,507 lines. The difference is edge cases found in production: IME composition, clipboard sequencing, mouse sessions, focus stealing, drag and drop.
- It reads the user's Ghostty config (`~/.config/ghostty/config` and friends) for fonts and themes, with live reload.
- Splits and tabs use Bonsplit, a SwiftUI tab bar and split-pane library (manaflow-ai/bonsplit, forked from almonk/bonsplit, MIT).

### Other native and web pieces

- File preview and editing: TextKit 1 NSTextView with Highlightr (highlight.js inside JavaScriptCore), see `Sources/Panels/FilePreviewSyntaxStyler.swift`. QuickLook and PDFKit for other file types.
- Diff viewer: a React web view that uses the Pierre diff parser (`@pierre/diffs`). Assets are served over an app-owned `cmux-diff-viewer://` scheme, so there is no TCP listener. The backend is a Rust sidecar (`Native/DiffSidecar`) that takes one typed request over stdin, answers on stdout and exits. It has a 5 MiB binary budget and a pinned Rust 1.88 toolchain.
- Markdown viewer and agent session renderers are also web.
- `cmux-tui/` is a Rust multiplexer daemon (crates `cmux-pty`, `ghostty-vt-sys`, `ghostty-vt`, `cmux-tui-core`, relays). Its `ghostty-vt-sys` crate builds libghostty-vt from the submodule with Zig. It runs durable headless sessions (`server start --session <name>`, sockets under `$TMPDIR/cmux-tui-<uid>/`). The Mac app follows its event stream for cloud machines.

### How it detects agent status

Three signals, in order of trust.

1. Agent hooks. For Claude Code, `Resources/bin/cmux-claude-wrapper` is a 2,345-line bash shim placed first on PATH inside cmux terminals. When `CMUX_SURFACE_ID` is set it intercepts `claude` and adds `--session-id` and `--settings <json>`, so Claude's hooks call back into cmux. It does not touch `~/.claude/settings.json`. A separate `cmux claude-hook install` writes user settings for sessions that start outside cmux, such as an existing tmux server. Other agents get hooks through `cmux hooks setup` (Codex, OpenCode, Gemini, Cursor CLI, Copilot, Amp, Pi and more). The Codex wrapper appends per-run `-c hooks.<event>=` flags.
2. Hooks write `~/.cmuxterm/<agent>-hook-sessions.json` with session id, workspace and surface id, cwd, pid, lifecycle (`running`, `idle`, `needsInput`, `unknown`) and a sanitized launch command. cmux uses it to resume agents on relaunch (`claude --resume <id>`) and for "agent hibernation", which SIGTERMs idle off-screen agents above a live limit and resumes them when you return.
3. Terminal escape sequences OSC 9, 99 and 777. cmux suppresses raw OSC notifications on panes that run a hook-integrated agent so they don't double up, and bridges Claude's PushNotification tool through a PostToolUse hook.
4. Process inspection as a last resort (`CmuxTopProcessSnapshot+PromptAgentDetection.swift`).

### How the CLI talks to the app

- `cmux` is a Swift CLI (`CLI/cmux.swift` alone is 1.9 MB) that connects to a Unix socket. The default path is `/tmp/cmux.sock`, with separate paths for nightly, rc and staging builds. Each terminal gets `CMUX_SOCKET_PATH`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID` and `CMUX_TAB_ID`, so commands target the caller's own pane by default.
- Protocol v2 is newline-delimited JSON, one `{"id","method","params"}` object per line. A legacy v1 text protocol still exists. `cmux rpc <method> <json>` calls any method, `cmux capabilities` lists them.
- `cmux events` sends `events.stream`, which takes over the connection and streams NDJSON frames. Every event has a monotonically increasing `seq` and a `boot_id`, clients reconnect with `after_seq`, and a restart shows up as a resume gap. Everything is also appended to `~/.cmuxterm/events.jsonl`.
- Access control modes: `cmuxOnly` checks the caller's process ancestry, so only the CLI and programs started inside cmux terminals get in. `password` and `allowAll` are the other two.
- cmux ships its own zsh, bash, fish and nushell integration (ZDOTDIR bootstrap). It reports cwd, TTY, prompt and running activity, git branch and PR hints, and "port-scan kicks" over the socket.
- Ports: `PortScanner.swift` coalesces kicks from all shells and runs one `ps -t <ttys>` plus `lsof -p <pids>` batch, at 0.5, 1.5, 3, 5, 7.5 and 10 seconds after a kick, instead of polling.

### Lessons for Mapo

- Budget for the terminal view's long tail. 14.6k lines is what "polished" cost them.
- A PATH shim that adds `--settings` keeps Claude's global config clean. Keep the shim short.
- An event stream with `seq`, `boot_id` and replay is a good model for `mapo events` and the MCP server.
- Process-ancestry socket auth is a sensible default for a local control socket.
- Trigger port scans from shell events and batch them.
- Keep terminals native, and use web views where native components are weak, which today means diffs and Markdown.

## 2. Ghostty and libghostty

### Release status in 2026

- Ghostty (<https://github.com/ghostty-org/ghostty>), MIT, 61.7k stars. v1.3.0 shipped 2026-03-09 and v1.3.1 on 2026-03-13. There is no later tag as of 2026-09-28, though main is very active.
- The 1.3.0 notes (<https://ghostty.org/docs/install/release-notes/1-3-0>) say libghostty was extracted as a standalone Zig module, the C API is work in progress, and "the Ghostty development team has decided to separate the Ghostty GUI and libghostty release cycles". They also added scrollback search, native scrollbars, OSC 133 click-events (click to move the cursor at a prompt), command-finished notifications (`notify-on-command-finish`, `-action`, `-after`), full ConEmu OSC 9 parsing (subcommands 1 to 12), the macOS audio bell and preview AppleScript support.
- The repo has no separately tagged libghostty release (tags are v1.3.1, v1.3.0 and tip). Mitchell's September 2025 post aimed at a tagged libghostty-vt within about six months. That has not visibly happened.

### The two C APIs

- `include/ghostty.h` is the full embedding API: PTY, VT, fonts, Metal renderer and input in one object. Its header comment now reads: "Ghostty's internal embedder API, a.k.a. 'libghostty-internal'. The only consumer of this API is the macOS app ... not designed for external use ... External embedders should instead use `libghostty-vt`". It exports 85 functions. cmux, Supacode, agterm, Calyx and OrbStack all use it anyway.
- `include/ghostty/vt.h` plus `include/ghostty/vt/*.h` is libghostty-vt. It covers terminal state, an incremental render state for custom renderers, a formatter (plain text, VT or HTML), snapshots (encode and incrementally restore terminal state), search, OSC and SGR parsers, paste safety, key, mouse and focus encoders (kitty keyboard protocol), kitty graphics with a host-supplied PNG decoder, and selection. It has no PTY, rendering or fonts. Its header says: "WARNING: This is an incomplete, work-in-progress API. It is not yet stable and is definitely going to change."
- Rust: the `libghostty-vt` crate, version 0.2.2 published 2026-09-28 (0.1.0 was 2026-03-28), repo <https://github.com/Uzaaft/libghostty-rs>, MIT OR Apache-2.0. The maintainer commits to ghostty-org/ghostty regularly. Its build.rs builds Ghostty from a pinned commit with Zig 0.16. Safe wrappers exist for Terminal, RenderState, KeyEncoder and MouseEncoder. On 2026-04-28 Mitchell publicly backed replacing Warp's Alacritty core with it.
- Swift: on 2026-07-02 Mitchell posted that he has "a pure Swift Metal renderer and bindings for libghostty-vt ... Coming soon". I found no public release.
- Official demos: `ghostty-org/ghostling` is a single C file terminal on libghostty-vt and raylib. `example/swift-vt-xcframework` in the main repo shows libghostty-vt consumed from SwiftPM.
- Community packaging: `Lakr233/libghostty-spm` (MIT, 111 stars) ships a prebuilt `GhosttyKit.xcframework` built weekly from upstream main with a 17-patch stack, including `0002-host-managed-io.patch`, iOS and visionOS fixes, and disabled inspector and custom shaders. It adds a `GhosttyTerminal` Swift wrapper with a SwiftUI view and an `.inMemory` backend where the host supplies the bytes. Rebuilding needs Zig 0.16 and the Xcode Metal toolchain.

### How the macOS app wraps a surface

- `macos/Sources/Ghostty/Ghostty.App.swift` creates the app with a `ghostty_runtime_config_s` holding callbacks: `wakeup_cb` (the host then calls `ghostty_app_tick` on the main thread), `action_cb` for every UI action, clipboard read, confirm and write callbacks, and `close_surface_cb`.
- `Ghostty.SurfaceView` is an NSView (`SurfaceView_AppKit.swift`). It passes itself as `nsview` in `ghostty_surface_config_s`, along with scale factor, font size, working directory, command, env vars, initial input, wait-after-command and a context flag (window, tab or split). libghostty renders with Metal into an IOSurface-backed layer. The view implements NSTextInputClient for IME, feeding preedit through `ghostty_surface_preedit`, and exposes an accessibility text area with the screen contents and selection.
- Tabs are native NSWindow tab groups (`addTabbedWindow`). Splits are a SwiftUI `SplitTree`. An embedder gets NEW_SPLIT, GOTO_SPLIT and NEW_TAB actions from keybindings but implements layout itself.
- Functions Mapo would use: `ghostty_surface_foreground_pid` and `ghostty_surface_tty_name` for process and port inspection, `ghostty_surface_read_text` for an MCP "read terminal" tool, `ghostty_surface_text` and `ghostty_surface_key` to send input.

### Shell integration and notifications

- Ghostty injects shell integration for bash, zsh, fish, elvish and nushell, found through `GHOSTTY_RESOURCES_DIR`. An embedder must bundle that resources directory (shell-integration scripts, terminfo). Integration gives OSC 133 prompt marks, jump-to-prompt, a bar cursor at the prompt, cwd reporting, sudo and ssh wrapping, and no close confirmation while at a prompt. macOS's bundled bash needs manual sourcing.
- Mapping to actions: OSC 7 becomes `GHOSTTY_ACTION_PWD` with the path. OSC 0 and 2 become SET_TITLE. OSC 9 and OSC 777 notify become DESKTOP_NOTIFICATION with title and body. OSC 9;4 becomes PROGRESS_REPORT with state and percent. OSC 133 D becomes COMMAND_FINISHED with exit code and duration in nanoseconds. BEL becomes RING_BELL. Child exit becomes SHOW_CHILD_EXITED. Upstream now also has an OSC 99 (kitty notification) parser, which cmux originally added in its fork.
- `src/termio/Exec.zig` sets `TERM_PROGRAM=ghostty` for child processes. Claude Code's default `preferredNotifChannel: "auto"` sends desktop notifications in Ghostty, iTerm2 and Kitty, and it draws an OSC 9;4 progress bar in Ghostty 1.2.0 and later. So a libghostty-based Mapo gets "Claude is working" and "Claude needs you" signals even without hooks. Hooks stay the source of truth.
- Images: kitty graphics protocol yes. The OSC 1337 parser implements only Copy and CurrentDir, so iTerm2 inline images do not work. Sixel was dropped from the TODO list in 2024 (PR #2772).

### Who embeds it

- OrbStack 2.0 (August 2025, commercial) as its built-in terminal.
- Native macOS agent terminals: cmux, Supacode, agterm, Calyx, Muxy, Factory Floor, Zentty, Mori, Mux0. con-terminal uses libghostty from Rust with Zed's GPUI.
- Nimbalyst, an Electron app, uses ghostty-web (libghostty compiled to WASM).
- Warp has two open issues (#9250 from 2026-04-28, #9913 from 2026-05-02) about replacing its Alacritty-derived core with libghostty-rs. A personal Zed fork has a migration plan to libghostty-vt. Nothing official from Zed.
- The list <https://github.com/Uzaaft/awesome-libghostty> has over 100 projects, including about 20 macOS agent terminals.

## 3. Terminal engine options

| Engine | License, latest | What you get | Rendering | Shell integration | Images | IME, keyboard, a11y | Embedding work |
|---|---|---|---|---|---|---|---|
| libghostty full, `ghostty.h` | MIT. Ghostty 1.3.1, main | PTY, VT, fonts, Metal renderer and input in one NSView | Metal, best of this list. cmux added pacing for background panes | OSC 7, 133, 9, 9;4, 777, 99, title and bell as typed actions. Auto-injected shell scripts | Kitty graphics. No sixel, no iTerm2 images | NSTextInputClient, kitty keyboard, AX text area. CJK fixes still landing | Medium to high. 2.5k lines for Ghostty's view, 14.6k for cmux's. Zig build or prebuilt xcframework. Internal API |
| libghostty-vt | MIT. Rust crate 0.2.2 | VT state, render state, encoders, snapshot and restore, search | None, bring your own | Parses all of it, you route events | Kitty graphics state, you draw it | Encoders only. IME and a11y are yours | Very high today. Much lower if Mitchell's Swift renderer ships |
| SwiftTerm | MIT. v1.20.0, 2026-08-18. main documents a 2.0 API | Engine plus AppKit and UIKit views, local PTY helper, or feed it bytes | CoreGraphics by default. Metal renderer is experimental and off by default | Delegates for OSC 7 cwd, OSC 777 notify, OSC 9;4 progress, OSC 133 semantic prompts, bell, title | Sixel, iTerm2, kitty | NSTextInputClient, Hangul input, kitty keyboard, `MacAccessibilityService` | Low. Used by CodeEdit, Secure ShellFish, La Terminal |
| alacritty_terminal | Apache-2.0. 0.26.0, 2026-04-06 | Grid, parser, PTY and event loop | None. Zed draws it with GPUI | No OSC 7, 133 or notifications. Zed gets cwd from the foreground process via `tcgetpgrp` and sysinfo | None | Kitty keyboard. IME and a11y are yours | High from Swift, the renderer has to cross FFI |
| rio-vt and librio | MIT. 0.5.28, 2026-09-17 | VT, grid, PTY spawning, host-pulled render state with per-row dirty flags. librio is a C ABI shipped as RioKit.xcframework | None. Rio itself uses sugarloaf on wgpu | Not verified for the lean core | Rio app does sixel, iTerm2 and kitty. Lean core not verified | Yours | High |
| wezterm-term and termwiz | MIT. termwiz 0.23.3, 2025-03. wezterm-term is not on crates.io | Rich model | None | WezTerm has OSC 7, 133 and notifications | Sixel, iTerm2, kitty | Yours | High, plus a git dependency on a project with no stable release since 2024-02-03 |
| vt100 crate | MIT. 0.16.2, 2025-07 | Simple screen model | None | Minimal | None | n/a | Only for headless screen reading and tests |
| Zed terminal | GPL-3.0 editor code | alacritty_terminal fork pinned by git rev, drawn with GPUI | GPUI | As alacritty | None | Weak a11y | Reference only, cannot embed in Swift |
| Warp | AGPL-3.0 client, MIT for the warpui crates. Open-sourced late April 2026 | Alacritty-derived model with command "blocks" | Own Rust GPU UI | Own shell hooks for blocks | n/a | n/a | Reference only |

Where the PTY lives matters more than which engine you pick. Three patterns show up in the reference apps.

1. libghostty owns the PTY. Upstream behavior, simplest. Quitting or crashing the app kills the children.
2. A separate daemon owns the PTY, and the Ghostty surface's command is an attach client. zmx (MIT, 2.2k stars, Zig) does this and keeps a libghostty-vt screen per session so a re-attach restores state. Supacode and agterm bundle zmx. Factory Floor and Mori use tmux. cmux offers tmux and its own cmux-tui daemon. Superset's Electron app has the same split in `packages/pty-daemon`: a detached PTY daemon adopted through a manifest file on restart, a socket in tmpdir kept under the 104-byte `sun_path` limit, 0600 permissions as the auth boundary, a versioned hello handshake, 4-byte length-prefixed frames, a 64 KB ring buffer per session, and file-descriptor handoff so shells survive daemon upgrades.
3. Host-managed IO. The app pushes bytes into the surface over FFI. Upstream `ghostty.h` has no such API, so this needs a patch, like libghostty-spm's `0002-host-managed-io.patch` or cmux's manual IO mode.

The Swift view code is identical for patterns 1 and 2. Only the surface's `command` changes. Start with 1 for plain shells and use 2 for server and agent tabs. If the daemon uses libghostty-vt through the Rust crate, keep it a separate binary from the Swift app that links GhosttyKit, so the two Zig builds never meet in one link.

My pick is libghostty. Agent panes stream a lot of output, several at once, and Ghostty's renderer and the cmux pacing patch are built for that. Its action set already covers cwd following, notifications, progress and command exit codes. And a dozen agent terminals have already paid the integration cost in public code you can read. SwiftTerm is the fallback if the Zig toolchain or API churn becomes a problem. It is the only option that takes host-fed bytes without patches and ships stable versioned releases, but its CoreGraphics renderer draws on the main thread. Its Metal renderer is still experimental: one small downstream A/B test in September 2026 (banyudu/banyan #79) reported roughly 50% more CPU per frame than CoreGraphics on streaming output.

## 4. Editor and viewer components

### Native options

| Component | License, latest | Notes |
|---|---|---|
| STTextView (krzyzanowskim) | GPL-3.0 or commercial license. 2.4.1, 2026-09-08 | TextKit 2 replacement for NSTextView and UITextView. macOS 14+. Line numbers, multi-cursor, completion, find and replace, spelling, plugins. Tree-sitter highlighting via STTextView-Plugin-Neon. Built for Swift Studio. The most mature native base. |
| CodeEditSourceEditor | MIT. 0.15.2, 2025-09-16 | Tree-sitter highlighting, completion, find and replace, minimap, SwiftUI and AppKit APIs. Its README says "currently in development and it is not ready for production use". Built on CodeEditTextView (0.12.1, 2025-07-30), a pure Swift text view tuned for fast layout of large files, whose own README points to STTextView for RTL or NSTextView parity. CodeEdit's last release was v0.3.6 on 2025-08-26, and activity has slowed. |
| CodeEditorView (mchakravarty) | Apache-2.0. 0.16.0, 2026-08-10 | SwiftUI on TextKit 2, inline messages, minimap, completion and hover through its LanguageSupport package. Author calls it pre-release quality. |
| Runestone | MIT. 0.5.2, 2026-03-25 | iOS only (UIKit). Not usable on macOS. |
| Chime (ChimeHQ) | BSD-3-Clause, open 3.0 alpha | A native macOS editor that highlights in three passes: regex patterns, then tree-sitter, then LSP semantic tokens. A good architecture reference. Its libraries moved: SwiftTreeSitter is now tree-sitter/swift-tree-sitter (0.10.0, 2026-03-18, BSD-3), ChimeHQ/Neon redirects to slsrepo/Neon (last tag 0.6.0 in 2024). LanguageClient 0.8.2 (2025-06) and LanguageServerProtocol 0.14.2 (2026-09-21) are still ChimeHQ. |
| Highlightr | MIT | highlight.js inside JavaScriptCore. What cmux uses for its NSTextView file preview. Cheap and good enough for a viewer. |

### LSP, git gutter, diff computation

- LSP is not needed for Mapo's current feature list. When it is, Swift has ChimeHQ LanguageClient and LanguageServerProtocol. Rust has lsp-types 0.97 (2024-06), async-lsp 0.2.4 (2026-04, client and server), and rust-analyzer's lsp-server 0.10.0 (2026-07). Helix (MPL-2.0) and Zed (GPL-3.0) have full clients to read.
- Git gutter in the Rust core: gix 0.88.0 (2026-09-25) or git2 0.21.0 to read HEAD and index blobs, imara-diff 0.2.0 or similar 3.2.0 for hunks, notify 9.0 (release candidate) for file watching. Helix's `helix-vcs` crate does its diff gutter with gix and imara-diff.
- tree-sitter 0.27.0 (2026-08-30, MIT) and tree-sitter-highlight 0.27.0 if highlighting should happen in Rust.

### Diff view

- Native Swift diff components are young. tornikegomareli/gitdiff has 80 stars and renders unified diffs in SwiftUI. DiffKit and Swift-Diffs (a Swift port of Pierre's diffs) were created in the last two weeks and have 0 or 1 stars. There is no mature native side-by-side diff editor.
- Web: `@pierre/diffs` 1.5.1 (Apache-2.0, pierrecomputer/pierre, 6.2k stars) is used by both Superset and cmux. Monaco's DiffEditor does side-by-side and inline. CodeMirror 6 has `@codemirror/merge` (MIT).

### Is Monaco in a WKWebView sane

Yes. Factory Floor (native Swift app on Ghostty) ships "Built-in Monaco editor (same engine as VS Code) embedded via WKWebView". Conductor's whole UI is a WebKit view inside Tauri. cmux, which otherwise goes native everywhere, uses WebKit for diffs and Markdown. SwiftyMonaco exists but has not been touched since 2023, so write the bridge yourself.

For Mapo specifically, the current app is a VS Code fork, so the Monaco decoration, diff editor and model APIs are already familiar. Practical rules:

- Keep one long-lived WKWebView, or a small pool, and swap Monaco models per file instead of creating a web view per tab.
- Serve assets through a `WKURLSchemeHandler` (a `mapo-editor://` scheme). No localhost server, no network entitlement.
- Pass open, save, dirty state and gutter decorations over `WKScriptMessageHandler`. Let the Rust core own file IO and git.
- Decide deliberately which Cmd shortcuts AppKit menus take and which reach the web view. Focus handoff between Ghostty's NSView and the web view is the usual source of bugs.
- Test IME and dead keys in Monaco on WebKit early. I did not verify its 2026 behavior.

The lighter alternative is CodeMirror 6 with `@codemirror/merge`, plus `@pierre/diffs` for review, which is Superset's choice.

### What is realistic for "click a file, it opens beside the terminal"

- v1: Monaco web view. Monarch grammars give highlighting for common languages, editing and find are built in. The gutter uses decorations whose hunks the Rust core computes against HEAD or the index. Diffs use Monaco's DiffEditor, side by side or inline. QuickLook for images and PDFs, as cmux does.
- Later, only if the web view feels slow to open: a native read-only viewer on STTextView (mind the GPL) or CodeEditTextView with tree-sitter highlighting, keeping the web view for editing and diffs.

## 5. Agent orchestration apps (2025-2026)

| App | Built with | Isolation | Agent status and notifications | Review | Dev servers and ports | Lesson for Mapo |
|---|---|---|---|---|---|---|
| Conductor (Melty Labs, YC S24, $22M Series A in 2026) | Tauri with React, a Rust core that spawns agent CLIs, WebKit view. Closed source. Homepage showed 0.87.6 | Git worktree per workspace | Live agent view. Bundles Claude Code and Codex | Diff viewer, checks, PR and merge | `.conductor/settings.toml` with setup, run and archive scripts. `CONDUCTOR_PORT` reserves 10 ports per workspace. `run_mode` concurrent or nonconcurrent. Stop sends SIGTERM to the process group, then SIGKILL after 5 s | Port blocks plus process-group kill semantics. Their rewrite post credits list virtualization and shutting down idle agents for speed, not the framework |
| Sculptor (Imbue) | Electron frontend (a PR bumps it to Electron 44), Python backend. MIT. Research preview | Launched October 2025 with Docker containers. The product page now describes worktrees | Claude plus experimental Pi | Per-workspace diff | Not mentioned | "Pairing mode" pulls an agent's work into your main checkout |
| Crystal, now Nimbalyst | Electron 43, Monaco, Lexical, node-pty, ghostty-web. MIT | Worktrees | Multiple agents in parallel | Visual editing of Markdown and mockups | n/a | Even Electron apps now pick libghostty (as WASM) for the terminal |
| Claude Squad | Go TUI, tmux, worktrees. AGPL-3.0. 8.5k stars | Worktrees | Background runs, auto-accept mode | Review before applying | n/a | tmux as the process owner goes a long way |
| Vibe Kanban (Bloop) | Rust backend, React UI, run with npx. Apache-2.0. 28k stars | Worktree per task, each with a terminal and dev server | 10+ agents | Inline diff comments sent to the agent | Built-in browser with devtools | Shutdown announced 2026-04-10, the team found no business model. These features commoditize fast |
| Superset | Electron 41, React 19, xterm.js 6.1 beta, node-pty, CodeMirror 6, @pierre/diffs, shiki. Elastic License 2.0. 14.7k stars | Worktrees plus setup and teardown scripts in `.superset/config.json` | Hooks call `~/.superset/hooks/notify.sh`, which posts to the host service (`SUPERSET_HOST_AGENT_HOOK_URL`). CLI, SDK and MCP | Diff viewer with edit and comments | Ports detected per workspace, browser pane | The pty-daemon design (above). Their July 2026 hooks investigation: they wrote hooks into global configs (`~/.codex/hooks.json`, `~/.factory/settings.json`) without an env guard, so hooks fired in terminals outside Superset |
| Orca (Stably) | Electron 43, xterm.js 6.1 with WebGL, node-pty, Monaco 0.55. MIT. 80.7k stars, v1.4.214 | Worktrees, SSH worktrees | Agent hooks, mobile companion | Line comments on AI diffs | Chromium browser with "Design Mode" | The largest app in the category runs on Electron, xterm.js and Monaco |
| Emdash (YC W26) | Electron, node-pty. Apache-2.0 | Worktrees | Multiple providers | n/a | n/a | One more Electron entrant |
| Supacode | Swift with The Composable Architecture, libghostty (upstream submodule plus a patches dir), zmx. FSL-1.1-ALv2. 2.4k stars, macOS 26+ | Worktree per task | Busy, awaiting input and idle badges from hooks it installs, local and over SSH | PR state and checks in the sidebar | Named scripts per repo, setup and archive scripts | Closest to a native Mapo. The CLI and `supacode://` deep links mirror each other |
| Factory Floor | Swift, Ghostty, tmux on a dedicated socket, Monaco in WKWebView. MIT | Worktree plus a Claude session per workstream | Claude session persistence | n/a | `.factoryfloor.json` setup, run and teardown. The WKWebView browser jumps to the port the run script opens | Mapo's shape in native form, and proof that the Ghostty plus Monaco mix works |
| agterm | Swift, libghostty, zmx. MIT | n/a | Status hooks for Claude Code and Codex. `agtermctl` controls almost everything over a local socket | n/a | n/a | Ships an installable agent skill that teaches Claude the CLI, so the agent can drive the app |
| Calyx | Swift, Ghostty. MIT. macOS 26, Apple Silicon | n/a | Agents sidebar (working, blocked, idle, done) with subagents, and one approvals inbox for permission prompts | Per-line diff comments sent to the agent | n/a | An approvals inbox beats hunting for the pane that is blocked |
| Warp | Rust with its own GPU UI. Client AGPL-3.0, warpui crates MIT, open-sourced late April 2026 | Local agents, plus the proprietary Oz cloud orchestrator | Agent Mode | Suggested diffs | n/a | Command "blocks" built on shell hooks |
| Zed agent panel | Zed 1.0 shipped 2026-04-29 (latest 1.21.0). ACP, JSON-RPC 2.0. The Claude Agent adapter wraps the Claude Agent SDK. Registry shared with JetBrains since 2026-01-28 | Threads side by side | ACP events | Zed's own diff review | n/a | ACP is the other way to host agents, talking to them directly instead of wrapping the CLI in a terminal |
| Claude Code desktop, Code tab | Electron (not re-checked) | Redesigned 2026-04-14. Every session gets a worktree under `.claude/worktrees/`, and `.worktreeinclude` copies gitignored files | Panes for chat, diff, browser, terminal, file, plan, tasks and subagents. OS notification when a session finishes while you are looking elsewhere | Diff view, PR and CI monitoring with auto-fix | `.claude/launch.json` preview servers with `autoPort` and `autoVerify` | Mapo's server tabs could read `.claude/launch.json` so one config serves both |
| Claude Code agent view (`claude agents`) | Part of the CLI, research preview | Background sessions | Rows show working, needs input or done. `--json` prints active sessions | Peek and attach | n/a | A status source Mapo could read, and a feature that now overlaps with Mapo's |
| OpenAI Codex app | Electron. macOS 2026-02-02, Windows 2026-03-04 | Worktrees | Threads, automations, skills, built-in terminal, sandboxing | Review queue | n/a | Chose Electron for cross-platform and got memory complaints |
| Cursor 2.0 (Oct 2025) Agents Window | VS Code fork | Worktrees or remote machines, up to 8 agents on one task | n/a | Compare results | n/a | Best-of-N on one prompt |
| Google Antigravity | VS Code fork (Nov 2025). 2.0 at I/O 2026 split into desktop app, CLI and SDK | Manager view across workspaces | n/a | Artifacts | n/a | A dedicated manager view separate from the editor |

Patterns across all of them:

- Everyone isolates with git worktrees. Per-repo config lives in the repo: `.conductor/settings.toml`, `.superset/config.json`, `.factoryfloor.json`, `.claude/launch.json`. Mapo's saved recipes could import these.
- Ports: Conductor reserves a block per workspace through an env var, Superset, Factory Floor and cmux detect what actually listens. Doing both works well. Assign a block, then confirm listeners per process tree. In Rust, `libproc` 0.14 or `listeners` 0.6 read sockets per pid without spawning `lsof`.
- Status: hooks are the truth, OSC notifications and progress are the fallback, process inspection is the last resort, and duplicates must be suppressed.
- Persistence: every app that keeps sessions across restarts puts PTYs in a separate process (Superset's pty-daemon, zmx, tmux, cmux-tui).
- Diff review with line comments sent back to the agent is now expected (Vibe Kanban, Superset, Orca, Calyx, cmux).

## 6. Recommendation for Mapo

### Terminal: libghostty full embed

1. Get GhosttyKit.xcframework either from libghostty-spm's weekly builds or from your own CI (Zig 0.16 plus the Metal toolchain). Pin the Ghostty commit and a checksum, as cmux does.
2. Wrap it behind a narrow Swift protocol, something like `TerminalView` with `send(text)`, `readScreen()`, `foregroundPID`, `ttyName` and an events stream. Keep `ghostty_*` calls out of the rest of the app. If the API churns, or Mitchell's Swift renderer for libghostty-vt ships, you swap the implementation behind that protocol.
3. Map actions to features. PWD drives the explorer. DESKTOP_NOTIFICATION, RING_BELL and PROGRESS_REPORT are fallback agent signals. COMMAND_FINISHED gives server tab exit codes and durations. SHOW_CHILD_EXITED feeds restart policies. SET_TITLE sets tab titles.
4. Plain shells can let libghostty own the PTY. Server and agent tabs run `mapo attach <session>` against the Rust core's PTY daemon. Keep that daemon a separate binary, versioned handshake from day one, with ring-buffer replay. Superset's pty-daemon README is the best checklist I found.
5. For Claude tabs, a PATH shim adds `--settings` with hooks (the cmux approach). Never write unguarded hooks into `~/.claude/settings.json`.

### Editor: Monaco in one WKWebView

Monaco covers editing, highlighting, find and the diff editor in one dependency Mapo's author already knows. The Rust core computes gutter hunks (gix plus imara-diff) and owns file IO. QuickLook handles binaries. Revisit native (STTextView plus tree-sitter) only if opening files feels slow.

### Risks

- `ghostty.h` is explicitly internal. It can change on any commit, and the build needs Zig. cmux carries about 40 patches and libghostty-spm 17.
- The long tail of the terminal view: IME, menu shortcut routing, focus, selection, drag and drop. cmux's view is 14.6k lines.
- With upstream libghostty the PTY lives in the app process. Persistence needs the attach pattern or a Ghostty patch.
- NSView terminals next to a WKWebView editor need careful focus and shortcut routing. Each web view also costs a WebContent process.
- Hook installation. Superset's global hooks leaked into unrelated terminals, and cmux's Claude wrapper grew to 2,345 lines of bash.
- The same notification can arrive through a hook and through OSC. Dedupe per session, as cmux does.
- Licenses of the reference code: cmux GPL-3.0, Zentty GPL-3.0, STTextView GPL-3.0 or paid, Warp AGPL-3.0, Supacode FSL, Superset Elastic 2.0. Read them, do not paste from them.
- The category moves fast. Claude Code itself now has worktrees, preview servers and an agent view. Vibe Kanban shut down in April 2026. For a personal tool that matters less, but features Mapo builds today may ship in Claude Code next month.

## 7. Not verified, or only from secondary sources

- Conductor's stack (Tauri, React, Rust core, WebKit) comes from performance.dev and third-party guides. Conductor's own homepage does not say. One secondary source also mentions an Elixir/Phoenix server.
- That the Claude desktop app is Electron: common knowledge, not re-checked today.
- Mitchell's pure Swift Metal renderer for libghostty-vt was announced 2026-07-02 as "coming soon". I found no public release.
- SwiftTerm Metal CPU numbers come from one small project's A/B test.
- Warp's open-source date is reported as April 28 or April 29, 2026.
- I ran no rendering benchmarks. Performance statements are qualitative.
- Image protocol support in rio-vt's lean core, and its shell-integration events, not checked.
- Monaco IME behavior inside WKWebView in 2026 not tested.
- Linking two separate Zig builds of Ghostty code, GhosttyKit and libghostty-vt, into one binary may cause duplicate symbols. I suggest separate binaries, but did not test it.
- The Zed libghostty migration exists only as a plan in a personal fork.

## Sources

cmux
- <https://github.com/manaflow-ai/cmux>
- <https://github.com/manaflow-ai/cmux/blob/main/docs/agent-hooks.md>
- <https://github.com/manaflow-ai/cmux/blob/main/docs/cli-contract.md>
- <https://github.com/manaflow-ai/cmux/blob/main/docs/events.md>
- <https://github.com/manaflow-ai/cmux/blob/main/docs/notifications.md>
- <https://github.com/manaflow-ai/cmux/blob/main/docs/ghostty-fork.md>
- <https://github.com/manaflow-ai/cmux/blob/main/docs/shell-integration.md>
- <https://github.com/manaflow-ai/cmux/blob/main/docs/configuration.md>
- <https://github.com/manaflow-ai/cmux/blob/main/Resources/bin/cmux-claude-wrapper>
- <https://github.com/manaflow-ai/cmux/blob/main/Sources/GhosttyTerminalView.swift>
- <https://github.com/manaflow-ai/cmux/blob/main/Sources/PortScanner.swift>
- <https://github.com/manaflow-ai/cmux/blob/main/Sources/Panels/FilePreviewSyntaxStyler.swift>
- <https://github.com/manaflow-ai/cmux/tree/main/Native/DiffSidecar>
- <https://github.com/manaflow-ai/cmux/tree/main/cmux-tui>
- <https://github.com/manaflow-ai/bonsplit>

Ghostty and libghostty
- <https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h>
- <https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h>
- <https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift>
- <https://github.com/ghostty-org/ghostty/blob/main/src/termio/Exec.zig>
- <https://github.com/ghostty-org/ghostty/blob/main/src/terminal/osc/parsers/iterm2.zig>
- <https://github.com/ghostty-org/ghostty/pull/2772>
- <https://ghostty.org/docs/install/release-notes/1-3-0>
- <https://ghostty.org/docs/features/shell-integration>
- <https://ghostty.org/docs/vt/reference>
- <https://mitchellh.com/writing/libghostty-is-coming>
- <https://x.com/mitchellh/status/2072724957902381319> (Swift renderer, 2026-07-02)
- <https://x.com/mitchellh/status/2049159764261925005> (Warp and libghostty-rs, 2026-04-28)
- <https://x.com/mitchellh/status/1960466661259022557> (OrbStack 2.0, 2025-08-26)
- <https://github.com/Uzaaft/libghostty-rs>, <https://crates.io/crates/libghostty-vt>
- <https://github.com/ghostty-org/ghostling>
- <https://github.com/Lakr233/libghostty-spm>
- <https://github.com/Uzaaft/awesome-libghostty>
- <https://github.com/neurosnap/zmx>

Terminal alternatives
- <https://github.com/migueldeicaza/SwiftTerm>, <https://github.com/migueldeicaza/SwiftTerm/issues/479>, <https://github.com/banyudu/banyan/issues/79>
- <https://github.com/alacritty/alacritty>, <https://crates.io/crates/alacritty_terminal>
- <https://github.com/zed-industries/zed/tree/main/crates/terminal>
- <https://github.com/raphamorim/rio/tree/main/rio-vt>, <https://github.com/raphamorim/rio/tree/main/librio>, <https://rioterm.com/docs/features>
- <https://github.com/wezterm/wezterm>, <https://crates.io/crates/termwiz>, <https://crates.io/crates/vt100>
- <https://github.com/warpdotdev/warp>, <https://www.warp.dev/blog/warp-is-now-open-source>, <https://github.com/warpdotdev/warp/issues/9250>, <https://github.com/warpdotdev/warp/issues/9913>

Editor components
- <https://github.com/krzyzanowskim/STTextView>, <https://github.com/krzyzanowskim/STTextView-Plugin-Neon>
- <https://github.com/CodeEditApp/CodeEditSourceEditor>, <https://github.com/CodeEditApp/CodeEditTextView>, <https://github.com/CodeEditApp/CodeEdit>
- <https://github.com/mchakravarty/CodeEditorView>
- <https://github.com/simonbs/Runestone>
- <https://github.com/ChimeHQ/Chime>, <https://github.com/tree-sitter/swift-tree-sitter>, <https://github.com/slsrepo/Neon>, <https://github.com/ChimeHQ/LanguageClient>, <https://github.com/ChimeHQ/LanguageServerProtocol>
- <https://github.com/raspu/Highlightr>
- <https://github.com/tornikegomareli/gitdiff>
- <https://github.com/pierrecomputer/pierre>, <https://www.npmjs.com/package/@pierre/diffs>
- <https://github.com/codemirror/merge>
- <https://github.com/ICToolkit/SwiftyMonaco>
- <https://github.com/helix-editor/helix>
- crates: gix, git2, imara-diff, similar, tree-sitter, lsp-types, async-lsp, lsp-server, libproc, listeners, sysinfo, notify

Agent orchestration apps
- <https://conductor.build>, <https://www.conductor.build/docs/reference/scripts>, <https://performance.dev/the-conductor-rewrite>, <https://codepick.dev/en/guides/conductor-build-intro/>
- <https://github.com/imbue-ai/sculptor>, <https://imbue.com/product/sculptor>
- <https://github.com/stravu/crystal>, <https://github.com/nimbalyst/nimbalyst>
- <https://github.com/smtg-ai/claude-squad>
- <https://github.com/BloopAI/vibe-kanban>, <https://www.vibekanban.com/blog/shutdown>
- <https://github.com/superset-sh/superset> (HOOKS_INVESTIGATION.md, packages/pty-daemon/README.md, packages/host-service/DAEMON_SUPERVISION.md)
- <https://github.com/stablyai/orca>
- <https://github.com/generalaction/emdash>
- <https://github.com/supabitapp/supacode>
- <https://github.com/alltuner/factoryfloor>
- <https://github.com/umputun/agterm>
- <https://github.com/yuuichieguchi/Calyx>
- <https://github.com/muxy-app/muxy>, <https://github.com/dedene/zentty>, <https://github.com/nowledge-co/con-terminal>
- <https://code.claude.com/docs/en/desktop>, <https://code.claude.com/docs/en/agent-view>, <https://code.claude.com/docs/en/hooks>, <https://code.claude.com/docs/en/terminal-config>, <https://code.claude.com/docs/en/settings-reference>, <https://code.claude.com/docs/en/cli-reference>
- <https://openai.com/index/introducing-the-codex-app/>, <https://www.devclass.com/development/2026/02/05/openai-codex-app-looks-beyond-the-ide-devs-ask-why-mac-only/4090132>
- <https://zed.dev/acp>, <https://zed.dev/docs/ai/external-agents>, <https://www.danilchenko.dev/posts/agent-client-protocol/>
- <https://cursor.com/docs/configuration/worktrees>
- <https://en.wikipedia.org/wiki/Google_Antigravity>
