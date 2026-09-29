# Mapo native: architecture

Status: approved direction (2026-09-28). This document says **how** Mapo native is built. [REQUIREMENTS.md](REQUIREMENTS.md) says **what** it must do, [PROTOCOL.md](PROTOCOL.md) defines the wire format, and [ENGINEERING.md](ENGINEERING.md) covers the dev loop, drivability and budgets. Research behind each choice is in [research/](research/).

## 1. Overview

```
Mapo.app  (Swift 6: AppKit shell; SwiftUI only for palette, settings, popovers)
  window: rail (NSSplitView sidebar, glass) | tiling panes | inspector (glass)
  panes:  GhosttySurfaceView (libghostty, Metal)   FileEditorView (TextKit 2)   DiffView
          each terminal surface runs `mapo attach <tab>` as its command
  MapoClient: one control connection  <-- JSON-RPC 2.0 (NDJSON) + event stream -->
  MapoAutomation: answers ui.* requests routed by the daemon
          |                                              |
          | control socket                               | attach connections (binary frames),
          v                                              v one per visible terminal
mapod  (the `mapo daemon` process, Rust, tokio; survives app quit, crash and rebuild)
  core actor: workspaces, tabs, layouts, status, activity, events   -> SQLite (WAL)
  term:  one PTY + login shell per tab, vte OSC pre-parser, alacritty_terminal emulator,
         2 MB raw ring buffer, attach fan-out, query answering while detached
  agent: Claude hook ingest, status machine, tab ask, resume ids
  proc:  server detection per tab, ports list, safe stop
  git/fs: listings, FSEvents watch, git status / numstat / diff through the git CLI
          ^                    ^                        ^
     mapo CLI           mapo mcp (stdio, rmcp)     mapo hook  <- Claude Code plugin hooks
   (humans, agents)     (launched by Claude)          (inside tabs only)
```

Principles:

1. **Commands are the feature boundary.** Every behavior is a daemon command. The UI, CLI, MCP, hooks and automation are thin clients.
2. **The daemon owns state and processes.** The app holds no state it can't rebuild from `state.snapshot` plus events.
3. **The app never sees PTY bytes on its control path.** Terminal bytes flow only through `mapo attach` connections owned by libghostty surfaces.
4. **One Rust binary and one Swift app.** `mapo` has subcommands: `daemon`, `attach`, `hook`, `mcp`, `ui`, plus the CLI verbs. It is small and starts in milliseconds.

## 2. Processes and bundle layout

| Process | Started by | Lifetime |
|---|---|---|
| `mapo daemon --instance I` (mapod) | the app, if not running (spawned detached with setsid); `just dev` in the foreground; later a login agent (SMAppService, M5) | Until stopped; outlives the app |
| `Mapo` (the app) | the user, `just app`, drives | Any time; reconnects to its instance |
| `mapo attach --tab T` | one per terminal surface, spawned by libghostty inside its own local PTY | While the surface exists; reconnects when the daemon restarts |
| login shell per tab | mapod, in a PTY it owns | Until the tab closes |
| `mapo hook` | Claude Code, through the plugin's hooks | Milliseconds per event |
| `mapo mcp` | Claude Code, through the plugin's `.mcp.json` | While that Claude session lives |
| `mapo <verb>` | people and agents | One request, or a stream (`events --follow`) |

The installed bundle (`Mapo.app`, bundle id `dev.mapo.app`; dev builds use `dev.mapo.app.dev`):

```
Mapo.app/Contents/
  MacOS/Mapo                     Swift app
  Helpers/mapo                   Rust binary (daemon, attach, hook, mcp, CLI)
  Frameworks/                    GhosttyKit is linked statically where possible
  Resources/terminfo/78/xterm-ghostty   (macOS ncurses uses hex directories: 'x' is 78)
  Resources/shell-integration/   zsh (v1), bash and fish (SHOULD)
  Resources/claude-plugin/       Claude Code plugin (hooks, .mcp.json, skills/mapo)
  Resources/bin/mapo -> ../../Helpers/mapo   the PATH entry injected into tabs
```

The Rust binary must not sit next to `MacOS/Mapo`. The volume is case-insensitive, so `MacOS/mapo` and `MacOS/Mapo` would be the same file. The app accepts `--instance NAME` and `--no-spawn-daemon`; drives use the latter when they start the daemon themselves.

## 3. The daemon (mapod)

### 3.1 Crates

| Crate | Responsibility | Key dependencies |
|---|---|---|
| `mapo-protocol` | Wire types, method names, error kinds, events, attach frame codec; source of the generated Swift types | serde, serde_json, typeshare (codegen) |
| `mapo-instance` | Instance names, paths, runtime dir, locks, tokens | libc (confstr for DARWIN_USER_TEMP_DIR) |
| `mapo-core` | State model, command dispatch, validation, guards, activity, event ring, persistence | rusqlite (bundled), uuid, time |
| `mapo-term` | PTY spawn, env, shell integration, OSC pre-parser, emulator, ring buffer, attach sessions, queries | pty-process (async), rustix, vte, alacritty_terminal |
| `mapo-agent` | Claude adapter: plugin env, hook ingest, status machine, ask, resume | (core types only) |
| `mapo-proc` | Process tree per tab, listening ports, identities, safe stop, server detection | libproc, listeners |
| `mapo-git` | Repository discovery, `.git/HEAD` branch, `git status` / `diff --numstat` / `diff` via the git CLI, fs listing, watching | notify, notify-debouncer-full, ignore |
| `mapo-mcp` | MCP server mapping tools to protocol calls | rmcp (pinned exact version) |
| `mapo` (bin) | clap CLI, `daemon` main, `attach`, `hook`, `mcp`, `ui` | tokio, clap, tracing |

The crate versions are the ones checked on 2026-09-28 (see research/core-crates.md):

| Crate | Version |
|---|---|
| pty-process | 0.5.3 |
| rustix | 1.1.5 |
| alacritty_terminal | 0.26.0 |
| vte | 0.15 |
| libproc | 0.14.11 |
| listeners | 0.6.1 |
| rmcp | 3.5.0 (pin exactly; its API churns) |
| notify | 8.2.0 |
| notify-debouncer-full | 0.7.0 |
| ignore | 0.4.33 |

Verify before pinning.

Justifications for the dependencies added in M1:
- `ignore` 0.4.33 (Unlicense/MIT): gitignore-aware one-level listings with global and repo excludes, the engine ripgrep uses.
- `notify` 8.2.0 (CC0): FSEvents watching without our own CoreServices bindings.
- `notify-debouncer-full` 0.7.0 (MIT/Apache-2.0): the 150 ms debounce, with `NoCache` so watching a git dir doesn't walk the tree.
- SwiftTerm 1.11.2 (MIT): the terminal renderer while GhosttyKit can't be acquired (see PROGRESS).

Deliberately not used in v1:

- **gix:** the git CLI plus a direct `.git/HEAD` read is enough and keeps builds fast.
- **UniFFI / BoltFFI:** the app speaks the socket protocol.
- **libghostty-vt in the daemon:** it needs Zig, and linking two Ghostty builds into one binary may clash. alacritty_terminal is pure Rust.

### 3.2 Concurrency model (tokio)

- **Core actor.** One task owns all state: workspaces, tabs, layouts, status, activity and the event ring. Requests arrive over an mpsc channel and are handled one at a time, with no locks. Handlers that must wait (`tab.wait`, `tab.run`, `tab.ask`) register a waiter and return later; they never block the actor.
- **Persistence.** A dedicated blocking thread owns the rusqlite connection. The core sends it write batches after each mutation, and the core never waits on disk for a response.
- **Tab tasks.** Each tab has a task that:
  - reads the PTY and runs the OSC pre-parser, which reports cwd, prompt/command marks, exit codes and title to the core
  - feeds the emulator, which the tab task owns
  - appends to the ring buffer
  - broadcasts chunks to attach sessions.

  It answers `read`, `snapshot` and `grid` queries from the core by message.
- **Attach sessions.** Each is one task per connection. It gets a bounded broadcast receiver from its tab. If a client lags past the bound, the session is resynced: a new replay, not dropped bytes.
- **Scanners.** Proc and git/fs scanners are tasks that the core triggers (a command started or ended, fs events). They post results back to the core.
- **Events.** The core appends each event to a bounded ring and broadcasts it to subscribers. Each connection has an outbound queue. A slow subscriber is disconnected with a cursor-expired error rather than slowing the core.

### 3.3 State model (daemon side)

```text
Instance   { bootId, activeWorkspaceId, workspaces[order] }
Workspace  { id, name, order, agentCommand, activeTabId?, layout: Layout, createdAt }
Layout     { root: Node, focusedPaneId }
Node       = Split { id, axis: row|column, children: [Node], ratios: [f64] }
           | Pane  { id, content: Tab(tabId) | File(path) | Diff(repoRoot, path) | Empty, recentFiles[] }
Tab        { id, workspaceId, name, labeled: bool, title, kind: shell|agent, order,
             launch: { cwd, command?, agentCommand? },
             cwd, foreground: { pid?, program? },
             state, stateLabel, stateDetail?, statusSource: shell|hooks|title|screen,
             lastExit?: { code, durationMs, at },
             server?: { ports: [u16], since },
             agent?: { hooksConnected, sessionId?, interruptedAt?, turnStartedAt? },
             launchError?: { kind, message, path? }, attention: bool, viewedAt? }
Activity   { id, at, caller, command, target, outcome, error? }
```

Status is computed in one place: `mapo-core::status`, a pure function with unit tests, which maps the raw facts above to `state` and `stateLabel`. The rail, headers, notifications, CLI and MCP all read the computed fields.

The daemon produces the user-facing strings: `stateLabel`, `stateDetail` (for example the needs-you reason), the workspace `summary` phrases, the Changes `warn` text and the `launchError` kinds and messages. UX.md §7 and §11 define their exact wording and templates. The daemon must match UX, and a copy change updates both.

### 3.4 Terminal pipeline

**Spawning a tab**

1. The core validates the cwd. If it is missing, the tab gets `launchError` and stays in the workspace (R-TAB-9).
2. `mapo-term` opens a PTY (pty-process) and spawns `$SHELL -l -i`, with `-l` only for login-style shells. Agent and command tabs send their command through the interactive shell once the first prompt appears (OSC 133;A). This keeps aliases working.
3. Environment: the R-TAB-4 variables. `ZDOTDIR` points to Mapo's zsh integration directory, whose `.zshenv` and `.zshrc` restore the user's `ZDOTDIR`, source the user's files, then install `precmd`/`preexec` hooks that emit OSC 7, OSC 133 A/B/C/D;exit and OSC 2. Write this small script ourselves. Do not copy Ghostty's zsh or bash integration: those are GPL-3.0 (derived from Kitty), even though Ghostty itself is MIT.
4. The process group and session come from pty-process, which starts the child as the leader of a new session with the PTY as its controlling terminal.

**Output path**

```
PTY master -> tab task -> vte pre-parser (OSC 7/133/0/2/9/777, BEL) -> core facts
                        -> alacritty_terminal Term (grid + scrollback, 2,000 lines default; libghostty keeps the long scrollback)
                        -> ring buffer (2 MB raw bytes, cut at a safe escape boundary)
                        -> broadcast -> attach sessions -> `mapo attach` -> libghostty surface
```

**Input path**

```
key in GhosttySurfaceView -> libghostty encodes -> its local PTY -> `mapo attach` (raw mode)
   -> IN frame -> attach session -> PTY master write
```

`tab.send` from the CLI writes to the same PTY master through the core. Bracketed paste is used for multi-line text and prompts.

**Attach**

- The hello carries the tab, its size and the app credential.
- The daemon replies, then sends `REPLAY`:
  - a terminal reset
  - the ring buffer contents
  - a mode-restore trailer from the emulator's state (alternate screen, cursor visibility, bracketed paste and mouse modes, current cursor position)
- After that it streams live `OUT` frames.
- The client sends `IN` frames and `RESIZE` frames on `SIGWINCH`.
- Size policy: the most recently resized or focused client wins. The daemon resizes the PTY (TIOCSWINSZ) and the emulator.
- **Queries while detached.** When no client is attached, the daemon's emulator answers DA1, DA2, DSR/CPR and XTVERSION so programs never hang. While any client is attached, the emulator's replies are dropped and the real terminal answers.
- **Reconnect.** When the daemon connection drops, `mapo attach` prints a dim `reconnecting…` line and retries with backoff for 30 s. On each attempt it re-reads `app.token`, since a restarted daemon issues a new one. After reconnecting it clears the screen and replays. If it gives up, it exits with a message, and the surface shows Mapo's "Disconnected: Reconnect" overlay.
- If replaying raw bytes proves imperfect (for example, a truncated alternate-screen app), switch to rendering the emulator grid into escape sequences. Keep this behind `ReplayStrategy`.

**Why attach and not host-fed surfaces.** Upstream libghostty spawns and owns the PTY of each surface. Host-managed IO exists only in forks: cmux's fork, and libghostty-spm's `0002-host-managed-io.patch`. The attach hop (the tmux/zmx pattern) works with the stock `ghostty.h`. The Swift side hides the choice behind `TerminalSurface` (§4.3), so moving to host-fed IO later is a local change.

### 3.5 Claude integration

**Plugin** (`Resources/claude-plugin/`, `plugin/` in the repo):

```
.claude-plugin/plugin.json      name "mapo", version
hooks/hooks.json                every event below -> command: [ -n "$MAPO_TAB_ID" ] && exec mapo hook || exit 0
.mcp.json                       { "mcpServers": { "mapo": { "command": "mapo", "args": ["mcp"] } } }
skills/mapo/SKILL.md            the agent skill (R-CTL-8)
```

**Injection.** Every tab's environment gets `CLAUDE_CODE_PLUGIN_DIRS=<existing>:<plugin dir>`. When `claude --version` reports less than 2.1.280, the daemon adds `--plugin-dir <plugin dir>` to agent tab commands instead (R-AG-1). Nothing is written to the user's settings, and there is no wrapper script.

**Hook path**

```
Claude -> hook command -> `mapo hook` (reads the hook JSON on stdin, adds MAPO_TAB_ID and MAPO_HOOK_TOKEN)
       -> hook.report -> mapo-agent status machine -> core -> events -> rail, notification
```

- `mapo hook` always exits 0 within 2 s and never blocks Claude.
- The daemon keeps only these fields:
  - `hook_event_name`
  - `session_id`, `source`, `cwd` and `transcript_path` (SessionStart), needed for resume (PA-6)
  - `agent_id` (the execution scope)
  - the notification type
  - `prompt_id` (UserPromptSubmit)
  - `tool_name` plus a summary of `tool_input` of at most 80 characters, such as the Bash command or the file path (PermissionRequest). This drives needs-you details like "Approve: pnpm db:migrate" and is dropped once the tab leaves `needs-you`.
  - `last_assistant_message` (Stop, held only while a `tab ask` is pending)

**Events handled:** SessionStart, UserPromptSubmit, Notification, PermissionRequest, PostToolBatch, SubagentStart, SubagentStop, Stop, StopFailure, SessionEnd. The mapping is R-AG-3; the logic is a port of `browser/mapoAgentSessions.ts` from the VS Code build (see FEATURE-MAP).

**Fallbacks without hooks:**

- Title parsing: ✳ means idle; spinner glyphs mean working.
- A screen matcher for the trust and login dialogs, run on the emulator grid while hooks are not connected. Its strings live in config so they can be updated without a build.

**`tab ask`:** the waiter chain wait-idle, then paste, then UserPromptSubmit, then Stop, returning `last_assistant_message`. If the target needs you during the ask, it returns exit code 5.

**Resume:** each tab stores `session_id` from SessionStart. When the daemon restarts, an agent tab launches `<agentCommand> --resume <session_id>` (R-AG-7).

### 3.6 Servers and processes

- **Per-tab detection** (R-SRV-1/2):
  1. The scan is triggered by OSC 133 C/D, then runs on a backoff schedule while the command is running.
  2. List the processes whose controlling tty is the tab's PTY (libproc, filtered by tty).
  3. For each, read its socket file descriptors and collect TCP sockets in LISTEN state and their ports.
  4. Set `tab.server = { ports }` when there are any, and clear it on the next command start.
- **Failure** (R-SRV-3): a command that was serving and ends with a non-zero OSC 133;D exit code sets `lastExit` and the tab's state to failed.
- **Ports list:**
  1. `listeners` gives the current user's LISTEN sockets.
  2. Each pid maps to a tab by the tab's tty, or failing that by ancestry up to a tab shell pid.
  3. Each process gets an identity: a hash of pid, start time and executable path.
- **Stop** (R-SRV-5):
  1. Re-read the process and require the same identity.
  2. Refuse Mapo, mapod, their ancestors and other users' processes.
  3. Send SIGTERM to that one pid and report `signalSent`.

### 3.7 Files and git

- `fs.list {path}` lists one directory level with ignore rules (the `ignore` crate: gitignore plus configured excludes). Each entry carries its git status from the repository cache.
- `fs.watch {path}` starts a notify watcher (FSEvents), debounced to 150 ms. It emits `fs.changed { root, paths }` and marks the git cache dirty.
- The repository cache lives per root. `git` runs with `-c core.fsmonitor=false --no-optional-locks`:
  - `status --porcelain=v2 -z --branch --untracked-files=all` for statuses and ahead/behind.
  - `diff --numstat -z HEAD` for line counts.
  - `diff --no-color -U3 HEAD -- <path>` for the diff view.
  - `show HEAD:<path>` for the editor's gutter base text.
  - The branch comes from reading `.git/HEAD`, following worktree `gitdir:` files.
- The app asks for listings lazily as the outline view expands. The daemon never pushes whole trees.

### 3.8 Persistence and configuration

- `state.db` (SQLite, WAL) has the tables `meta`, `workspaces`, `tabs`, `layouts`, `file_panes`, `agent_sessions` and `activity` (bounded to 5,000 rows). Migrations are numbered SQL files embedded in the binary.
- `config.toml` in the instance directory, watched and hot-reloaded:

  ```toml
  [terminal]  # font-family, font-size, theme, scrollback-lines, option-as-alt
  [shell]     # program (default $SHELL), integration = true
  [agent]     # default-command = "claude", trust-dialog-patterns = [...]
  [attention] # notify = ["needs-you","failed","done"], done-threshold-seconds = 30
  [files]     # exclude = [".DS_Store", "node_modules"], respect-gitignore = true
  [changes]   # warn-lines = 1500, warn-files = 50
  [ui]        # theme = "mapo-glass", appearance = "system", reduce-transparency = "system", rail-width = 280, inspector-width = 300
  ```
- Editor recovery copies go in `recovery/`. Logs go in `logs/` (daily files, 7 kept).

### 3.9 Security model

- **Filesystem.** The runtime dir is `$(getconf DARWIN_USER_TEMP_DIR)mapo/` with mode 0700. For each instance it holds `<instance>.sock` (0600), `<instance>.lock`, `<instance>.pid` (daemon) and `<instance>.app.pid` (app). The daemon checks the peer uid on accept (`getpeereid`) and refuses other users.
- **Credentials.** Each role gets a scoped credential (PROTOCOL §3):
  - `app`: a random token written to the instance directory with mode 0600. The app uses it; so does the automation surface and anything run by the same user (operator rights).
  - `tab`: `MAPO_TOKEN` per tab. The caller is that tab; destructive actions on other tabs need `force`.
  - `hook`: `MAPO_HOOK_TOKEN` per tab. It can only call `hook.report` for its own tab.
  - `attach`: the app token plus a tab id.
- **Secrecy.** Tokens never appear in events, activity entries, logs or process arguments; they travel in the environment only.
- **Local-only.** There is no TCP listener. This is a same-user boundary, not a sandbox, the same stance as the VS Code build.
- **Code signing.** Unsandboxed, hardened runtime, with the entitlements and usage strings from R-NF-4.

## 4. The Swift app

### 4.1 Targets and modules

```
app/project.yml                  XcodeGen spec -> Mapo.xcodeproj (generated, gitignored)
app/Mapo/                        app target: AppDelegate, MainWindowController, menus, Info.plist, entitlements
app/Packages/MapoKit/            local SwiftPM package
  MapoProtocol    generated Codable types (Swift 5 language mode) + small hand-written extensions
  MapoClient      control connection (Network.framework, .unix endpoint), NDJSON JSON-RPC, reconnect,
                  AppStore (@Observable, MainActor) fed by state.snapshot + events
  MapoTerminal    TerminalSurface protocol, GhosttySurfaceView (GhosttyKit), SwiftTermSurfaceView (fallback only)
  MapoEditor      TextKit 2 editor, tree-sitter highlighting, gutter, unified DiffView
  MapoUI          rail, split-tree container, pane headers, inspector (Files, Changes), palette, theme
  MapoAutomation  ui.* handlers: AX tree, semantic snapshot, synthetic input, waits, metrics
```

Swift 6 language mode with MainActor default isolation for app code. Generated protocol types stay in Swift 5 mode (research/interop-build.md).

### 4.2 AppKit versus SwiftUI

AppKit owns the app lifecycle, windows, `NSSplitViewController`, the rail (`NSOutlineView` with custom 24/26 px row views), the file tree (`NSOutlineView`), the tiling container, the editor (NSTextView on TextKit 2), menus, key routing and focus.

- Rail: the sidebar split item, so macOS 26 gives it a floating Liquid Glass sidebar.
- Inspector: the inspector split item.

SwiftUI is only for the ⌘K palette (in an `NSPanel`), settings, popovers and hover cards. The reason: cmux replaced a SwiftUI sidebar with NSTableView after CPU livelocks, and Ghostty moved its splits out of SwiftUI (research/interop-build.md §5).

### 4.3 Terminal surfaces

```swift
@MainActor protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    var tabId: String { get }
    func focus()
    func setVisible(_ visible: Bool)
    var onTitle: ((String) -> Void)? { get set }   // UI hint only; daemon is the source of truth
    var onBell: (() -> Void)? { get set }
    var onExit: ((Int32?) -> Void)? { get set }    // the child exited on its own; the host shows the scrim
    func close()                                   // stop the child; build a new surface to reattach
}
```

- **`TerminalHostView`** is a pane's terminal body: the tab's current surface plus the "Disconnected" scrim (UX §4.3). It outlives surfaces, so Reconnect swaps the surface in place. **`SurfaceRegistry`** keeps one host per tab id until the tab closes, so re-layout never rebuilds a surface.

- **`GhosttySurfaceView`** hosts a `ghostty_surface_t` configured with:
  - `command = "<bundle>/Contents/Helpers/mapo attach --tab <id> --instance <I>"`
  - env `MAPO_INSTANCE` (the attach client reads the app token from the instance directory on every connect, because tokens rotate each time the daemon boots)
  - `wait-after-command = false`
  - `shell-integration = none`
  - the app owns font and theme settings.

  It follows Ghostty's macOS `SurfaceView` for NSTextInputClient, key and mouse handling, and display-link driven rendering, keeping only what Mapo needs.
- **GhosttyKit source.** A prebuilt `GhosttyKit.xcframework` from `Lakr233/libghostty-spm` (MIT), with the release and SHA-256 pinned in `third_party/ghostty.lock` and cached in `~/Library/Caches/mapo/ghostty/<version>/`. Only upstream `ghostty.h` APIs are used. The fallback is building upstream Ghostty at a pinned commit with Zig 0.16. Both paths are described in PLAN T0.8.
- **Module map.** GhosttyKit's header module must not collide with anything else's module map. Nest headers under `Headers/GhosttyKit/` if a second library XCFramework is ever added (swift-build #1746).
- **Visibility.** Terminal views of tabs outside the visible panes are detached from the view tree after 30 s of being hidden. Their `mapo attach` processes exit and reattach on demand. Replay makes this invisible and keeps idle cost near zero.
- **Fallback.** `SwiftTermSurfaceView` (SwiftTerm, MIT) runs `mapo attach` through SwiftTerm's `LocalProcess`. Use it only if GhosttyKit blocks M0 (PLAN T0.8).

### 4.4 Editor and diff

- **Text view.** `NSTextView(usingTextLayoutManager: true)`, with a custom gutter view that draws line numbers and git hunk bars. It enumerates `NSTextLayoutFragment`s for visible lines. STTextView (GPL-3.0, acceptable for personal use) is allowed if the gutter or performance work becomes a sink; record that in DECISIONS.md.
- **Highlighting.** SwiftTreeSitter plus Neon (BSD-3), with grammars from individual tree-sitter packages or CodeEditLanguages (MIT). Check each grammar's license when adding it.
- **Gutter.** The base text comes from the daemon (`git.baseText`). The diff runs in-app on lines with `CollectionDifference`, debounced 200 ms, so unsaved edits show immediately.
- **DiffView.** A read-only text view over `git.diff` output, with line backgrounds for added and removed lines and hunk headers.
- **Recovery.** File I/O is in the app, which reads and writes the file directly. The daemon only learns paths, for layout persistence and `file open` routing. Autosave writes recovery copies every 5 s while a buffer is dirty.

### 4.5 Notifications, dock and focus

- `UNUserNotificationCenter` is authorized lazily on the first attention event. The notification identifier is the tab id, so repeats coalesce, and clicking one runs `tab.focus`.
- The dock badge is `NSApp.dockTile.badgeLabel`, set to the needs-you count.
- Visibility for R-ST-4 is decided by the app from the window's key state, the active workspace and the visible panes. The app sends `ui.visibility` updates to the daemon so the daemon can mark `done` as viewed.

### 4.6 Automation host

`MapoAutomation` registers with the daemon (`app.register { capabilities: ["ui"] }`) and serves the `ui.*` methods from PROTOCOL §6.8. The usage contract is in ENGINEERING §4. How it works:

- **Element tree.** It walks `NSAccessibility` elements (`accessibilityIdentifier`, role, label, value, frame, focus and enabled state).
- **Input.** It synthesizes `NSEvent`s posted to the app's own event queue: clicks at element centers, key chords and text. Because the events are in-process, no Accessibility permission is needed.
- **Metrics.** It uses `CADisplayLink` / `NSScreen.displayLink` for frame pacing, and timestamps for launch, navigation and attach latency.
- **Pixels.** Screenshots are taken outside the app: `screencapture -x -l <windowNumber>` run from an agent terminal that has Screen Recording permission (ENGINEERING §4).

## 5. Repository layout (code map)

```
mapo-native/                       (branch `native`, orphan; worktree of ~/code/mapo's repo)
├─ AGENTS.md                       agent instructions (CLAUDE.md -> AGENTS.md)
├─ README.md
├─ Cargo.toml  rust-toolchain.toml  .cargo/config.toml (MACOSX_DEPLOYMENT_TARGET=26.0)
├─ crates/  mapo-protocol  mapo-instance  mapo-core  mapo-term  mapo-agent  mapo-proc  mapo-git  mapo-mcp  mapo
├─ app/     project.yml  Mapo/  Packages/MapoKit/
├─ plugin/  .claude-plugin/plugin.json  hooks/hooks.json  .mcp.json  skills/mapo/SKILL.md
├─ resources/  shell-integration/zsh/  terminfo/
├─ third_party/ghostty.lock
├─ drives/  README.md  m0-skeleton.sh  …
├─ justfile  mprocs.yaml  .gitignore
└─ docs/   REQUIREMENTS  UX  ARCHITECTURE  PROTOCOL  ENGINEERING  PLAN  ROADMAP  DECISIONS
           FEATURE-MAP  HANDOFF  PROGRESS  research/  reference/
```

## 6. Designed-for extensions

- **Worktrees.** A `git.worktree.*` command family in `mapo-git`, using the git CLI. A tab's `launch.cwd` can point into a new worktree. The workspace is still folderless; each tab carries its own repository identity.
- **PR and review panel.** A new inspector segment "PR" backed by a `gh` adapter (`gh pr view --json`, `gh pr checks`). Review fan-out creates agent tabs and uses `tab.ask`, writing output outside the repo (for example `~/.mapo/reviews/`).
- **Browser pane.** A `Pane.content = Web(url)` variant rendered by WKWebView, with the URL from `tab.server`. Agents get `web.screenshot` and `web.text` through the daemon; cookies and storage are never exposed.
- **Managed servers, setups, actions, dekit import.** New columns and commands on existing rows; the protocol changes are additive only.
- **Other agent CLIs.** The `AgentAdapter` trait in `mapo-agent` is implemented by `ClaudeAdapter` first.

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| `ghostty.h` is "internal" and unstable; pinned prebuilts lag | Pin the version and checksum; wrap everything in `TerminalSurface`; SwiftTerm fallback; build from source with Zig 0.16 when needed |
| Replay fidelity on reattach | ReplayStrategy switch to emulator-grid rendering; drive `m0-skeleton` covers vim/htop/Claude reattach |
| Terminal query deadlocks while detached | The daemon emulator answers DA/DSR/XTVERSION only while no client is attached |
| Claude Code changes weekly (hooks, plugin env) | Version gate plus `--plugin-dir` fallback; matcher strings in config; one drive with real Claude per milestone |
| rmcp API churn | Pin the exact version; wrap it in `mapo-mcp` only |
| Pixel screenshots need Screen Recording | Semantic snapshots are primary; pixels come via `screencapture -l` from a terminal granted permission (HANDOFF pre-flight) |
| Daemon crash kills sessions | The core is small and separated; restore from definitions with Claude `--resume`; FD handoff later |
| TextKit 2 gutter and highlighting effort | Start with a minimal gutter; allow STTextView; limit languages in v1 |
| Focus and key routing between AppKit views and Metal surfaces | One focus manager in MapoUI; drives cover the ⌘K palette → terminal → editor focus round trips |

## 8. References

- research/interop-build.md: interop, build pipeline, SwiftUI versus AppKit, jayjay as the build blueprint.
- research/domain-apps.md: cmux, Ghostty, Supacode, Superset (daemon checklist), editors.
- research/core-crates.md: PTY, ports, MCP, IPC, Claude hooks and plugin env, git, macOS integration.
- reference/vscode-build/: the command API, skill and feature research from the frozen VS Code build.
