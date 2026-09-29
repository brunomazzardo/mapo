# Mapo native: requirements

Status: approved in the interview of 2026-09-28. Sources: the interview (see [DECISIONS.md](DECISIONS.md)), the VS Code build on branch `mapo` (see [FEATURE-MAP.md](FEATURE-MAP.md)), and the research in [research/](research/).

Requirement IDs are stable. [PLAN.md](PLAN.md) and [ROADMAP.md](ROADMAP.md) refer to them. **MUST** is v1 scope. **SHOULD** is v1 if it is cheap, otherwise the first follow-up. **LATER** is designed for but not built in v1.

## 1. Product

Mapo is a native macOS home for parallel terminal and Claude Code work. A left rail holds named workspaces. Each workspace holds tabs: shells, Claude agents, and shells that happen to run dev servers. The center shows the workspace's tabs in tiling panes. A right inspector shows the files and git changes of the folder the focused terminal is in. Clicking a file opens it in a light native editor beside the terminal. Agents running inside Mapo control it through the `mapo` CLI and an MCP server, so a human and an agent drive the same app with the same commands.

- **User:** one person, the author. No onboarding, no accounts, no telemetry, no auto-updater.
- **Platform:** macOS 26 or later on Apple silicon. The dev machine runs macOS 27 and Xcode 27.
- **Stack:** a Rust daemon (`mapod`) owns processes and state; a Swift app (AppKit plus SwiftUI where it fits) renders; Ghostty's engine (libghostty) renders terminals. See [ARCHITECTURE.md](ARCHITECTURE.md).

### 1.1 Goals, in tie-break order

1. **Native feel and speed.** Real Liquid Glass materials, native menus, windows, text and focus behavior, instant launch, low memory.
2. **Terminal quality.** Ghostty-grade rendering, input latency, IME, keyboard protocols and image support.
3. **Reliability.** Sessions survive quitting, crashing and updating the app. No hidden states: every failure is visible and has a recovery path.
4. **A small codebase the author owns.** Every line is Mapo's, builds are fast, and agents can work on it in parallel worktrees.

### 1.2 Non-goals for v1

- Extensions, LSP, debugging, a VS Code-grade editor.
- Other agent CLIs (Codex, Gemini, opencode). Claude Code only; keep an adapter seam.
- Managed server definitions (saved commands, auto-start, restart policy). Servers are ordinary tabs in v1; see §3.9.
- Saved setups, repo membership, `.mapo/actions` scripts, mprocs/dekit integration. See §6.
- Importing workspaces from the VS Code build. The user starts fresh.
- Sandboxing, signing for distribution, notarization, auto-update.

## 2. Concepts

| Concept | Definition |
|---|---|
| Instance | One isolated Mapo world: its own daemon, socket, database, config and logs. The installed app uses instance `main`. Every dev build and every worktree uses its own instance. See [ENGINEERING.md](ENGINEERING.md). |
| Workspace | A named, ordered group of tabs. It needs no folder. It has an agent command, a tiling layout and an active tab. |
| Tab | One terminal session owned by the daemon. It has a stable **name** (its address for commands) and a live **title** (what people see). Its kind is `shell` or `agent`. |
| Pane | A cell of the workspace's tiling layout. A pane shows one tab or one file. A tab that is in no pane keeps running in the background. |
| Agent tab | A tab whose foreground program is Claude Code. Status comes from hooks. |
| Server | Any tab whose processes listen on a TCP port. Detected, not declared. |
| State | One word from the shared vocabulary in §3.5, used by every surface. |
| Attention | A tab in `needs-you` or `failed`, or `done` and not yet viewed. |

## 3. v1 requirements

### 3.1 Workspaces

- **R-WS-1 MUST** Create a workspace instantly with no prompt. The name is the first free "Workspace N". Rename it inline or with `workspace rename`. Delete it with a confirmation when any tab runs a foreground process; agents must pass `--force`.
- **R-WS-2 MUST** The rail lists workspaces in a saved manual order. Reorder by drag, or with `workspace move --index N`.
- **R-WS-3 MUST** Switching workspaces shows that workspace's layout at once. Every process in every workspace keeps running.
- **R-WS-4 MUST** The active workspace expands to show its tabs. Other workspaces are single collapsed rows with a status dot (UX §3).
- **R-WS-5 MUST** A workspace row shows the branch of the focused tab's repository inline and a badge counting its tabs that need you.
- **R-WS-6 MUST** Each workspace has an agent command (default `claude`, for example `claude-work`). New agent tabs use it; a tab may override it.
- **R-WS-7 MUST** A workspace's state is its most urgent tab state, by the priority in §3.5. A tab that is serving (R-SRV-1) is steady state: it shows its serving dot but never becomes the workspace's headline state or summary.
- **R-WS-8 LATER** Pin workspaces.

### 3.2 Tabs and terminals

- **R-TAB-1 MUST** There are two tab kinds. A **shell** tab is the user's login shell. An **agent** tab runs the workspace or tab agent command through the interactive shell, so aliases such as `claude-work` resolve. `tab new --cmd CMD` runs any command in the interactive shell.
- **R-TAB-2 MUST** ⌘T opens a shell tab in the focused tab's current folder with no prompt; with no focused tab it opens in the home folder. "New Tab in Folder…" asks for a folder. ⇧⌘T opens an agent tab the same way.
- **R-TAB-3 MUST** Names and titles:
  - The stable name is the address used by the CLI, MCP and the automation surface. It is unique within the workspace.
  - A name a person or agent chose is also the title.
  - An unnamed tab (`terminal-1`, `agent-1`) shows the live title: the shell or program title, or Claude's session title.
- **R-TAB-4 MUST** Every tab's environment gets:
  - `MAPO_INSTANCE`, `MAPO_WORKSPACE_ID`, `MAPO_TAB_ID`, `MAPO_TAB_NAME` and a per-tab capability `MAPO_TOKEN`.
  - `PATH` with the bundled `mapo` first.
  - `TERM=xterm-ghostty` plus `TERMINFO` pointing at the bundled terminfo (fall back to `xterm-256color` if it is missing), and `TERM_PROGRAM=ghostty`.
  - `CLAUDE_CODE_PLUGIN_DIRS` with Mapo's plugin appended.
  - Inherited `CLAUDE_CODE_*` session markers and inherited `MAPO_*` variables are removed first. The frozen app injects `MAPO_TAB_ID` and `MAPO_AGENT_TOKEN`, so a daemon started from one of its terminals must not pass them on.
- **R-TAB-5 MUST** Mapo injects shell integration so the daemon knows the cwd (OSC 7), prompt and command boundaries with exit codes (OSC 133), and the title (OSC 0/2). zsh is required in v1. bash and fish are SHOULD.
- **R-TAB-6 MUST** Tabs live in the daemon:
  - Quitting, crashing or rebuilding the app does not affect them.
  - Reopening the app reattaches every tab with its screen and recent scrollback.
- **R-TAB-7 MUST** Closing a tab asks for confirmation only when a foreground program other than the shell is running. Agents closing a tab other than their own must pass `--force`.
- **R-TAB-8 MUST** Tab order is saved per workspace. Reorder by drag or with `tab move`. The order drives ⌘1–⌘9 and next/previous tab.
- **R-TAB-12 MUST** A shell that exits with code 0 after its first prompt closes its tab, as terminals do. A non-zero exit or a signal leaves the tab `stopped`, with the code and a Restart action (FEATURE-MAP PA-20).
- **R-TAB-9 MUST** A tab whose launch fails (for example, its folder is missing) stays in the workspace:
  - It shows `Couldn't start` with the reason and a retry.
  - Focusing it retries, one attempt at a time.
  - Its definition is never deleted by a failure.
- **R-TAB-10 MUST** Terminal rendering, input, IME, selection, links, kitty keyboard and graphics, and font rendering come from libghostty. Font, size and theme are set in Mapo's config.
- **R-TAB-11 SHOULD** A shell command that ran for 30 seconds or longer (configurable) and has finished marks the tab `done` (exit 0) or `failed` (non-zero) until the tab is viewed.

### 3.3 Layout: tiling panes

- **R-LAY-1 MUST** Each workspace has a tiling layout: a tree of horizontal and vertical splits with ratios. Each leaf pane shows one tab, one file, one diff, or nothing.
- **R-LAY-2 MUST** Tabs appear only in the rail. There are no tab strips.
- **R-LAY-3 MUST** Selecting a tab in the rail focuses its pane if it is visible. Otherwise the tab replaces the content of the focused pane, and the replaced tab keeps running in the background. When the focused pane shows a file or diff, the tab goes to the most recently focused terminal pane instead; a file pane is never replaced by a terminal.
- **R-LAY-4 MUST** Pane operations:
  - ⌘D splits right and ⇧⌘D splits down. The new pane gets a new shell tab in the same folder.
  - ⌘W closes the focused pane. The tab keeps running unless its pane was the tab's only view and the user chose to close the tab.
  - Drag a divider to resize. "Equalize Panes" resets the ratios.
  - ⌥⌘ plus an arrow key moves focus between panes.
  - The layout is saved per workspace.
- **R-LAY-5 MUST** Opening a file (explorer click, `file open`, the palette) shows it in the workspace's file pane:
  - With no file pane yet, split right of the focused terminal.
  - The file pane keeps a small list of recent files; switching between them does not create more panes.
  - Focus moves to the editor.
- **R-LAY-6 MUST** Each pane has a slim header with its name and an urgent state word, its folder and branch (or URL, or file path), and actions:
  - Stop, only for working agents.
  - Stop (Ctrl-C) for a running shell command.
  - Diff and Close for files.
- **R-LAY-7 MUST** The focused pane shows an accent ring. Background status updates never move focus or scroll anything.

### 3.4 Claude agent tabs

- **R-AG-1 MUST** Mapo ships a Claude Code plugin with hooks, an MCP server entry and the `mapo` skill. It is loaded through `CLAUDE_CODE_PLUGIN_DIRS`, which needs Claude Code 2.1.280 or later; the machine has 2.1.284.
  - Mapo never edits the user's Claude settings and never wraps `claude` in a script.
  - With older Claude versions, agent tabs pass `--plugin-dir` instead.
- **R-AG-2 MUST** Any Claude session started in any Mapo tab reports status, including sessions typed by hand into a shell tab. Hooks do nothing outside a Mapo tab: they require `MAPO_TAB_ID` and a hook token.
- **R-AG-3 MUST** Agent status is derived from hook events:

  | Hook event | Effect |
  |---|---|
  | SessionStart, SessionEnd | idle; attention and subagents cleared |
  | UserPromptSubmit | running (Working); attention cleared |
  | PermissionRequest, Notification (permission_prompt, elicitation_dialog, elicitation_url_dialog, agent_needs_input), StopFailure | needs-you for that execution scope |
  | PostToolBatch | clears attention for that scope; running |
  | SubagentStart / SubagentStop | tracks running subagents; the tab stays running while any subagent runs |
  | Stop | done |

  More rules:
  - Stop does not fire on Esc, so Mapo records the interrupt itself and ignores late events until the next prompt.
  - Sessions without hooks fall back to title parsing: an idle title starts with ✳ and a working title shows spinner glyphs.
  - Claude's folder-trust or login dialog on screen counts as needs-you. Mapo never answers it.
- **R-AG-4 MUST** Interrupt with ⇧⌘X or the pane's Stop button, which appears only while the agent is working. It sends Escape. The session stays open for a follow-up.
- **R-AG-5 MUST** `tab ask NAME PROMPT`:
  1. Waits until the target is idle or done.
  2. Pastes the prompt with bracketed paste and submits it.
  3. Confirms the turn started through UserPromptSubmit.
  4. Returns the Stop hook's `last_assistant_message`.

  It exits 5 when the target needs the user and 124 on timeout. There is no screen scraping.
- **R-AG-6 MUST** Mapo records each agent tab's configured command and its Claude `session_id` from SessionStart.
- **R-AG-7 SHOULD** After the daemon restarts (reboot, crash or update), agent tabs relaunch with `<agent command> --resume <session_id>`.

### 3.5 Status and attention

- **R-ST-1 MUST** Every surface uses one vocabulary, in this priority order: `needs-you`, `failed`, `running`, `done`, `starting`, `stopping`, `idle`, `stopped`.
  - This covers the rail, pane headers, notifications, the CLI and MCP.
  - The display words are: Needs you, Failed (qualified as "exit 1" where there is room), Working (agents) or Running (commands), Done, Starting, Stopping, no word for idle, Stopped.
  - `Couldn't start` is a `failed` with a launch reason.
- **R-ST-2 MUST** The rail shows words only for Needs you and Failed. Working, running and done are small colored dots. Idle shows nothing. See UX §3.
- **R-ST-3 MUST** The dock badge shows the number of tabs that need you, across all workspaces.
- **R-ST-4 MUST** When a tab becomes needs-you, failed or done while you cannot see it, Mapo posts a macOS notification:
  - "Cannot see it" means Mapo is inactive, the tab is in another workspace, or the tab is in no visible pane.
  - Clicking the notification focuses the tab.
  - Duplicate notifications are coalesced, and macOS Focus is respected.
  - This requires the app to be running; without it the daemon only badges once the app opens.
- **R-ST-5 MUST** Clearing rules:
  - `done` clears when the tab has been visible and focused.
  - `failed` clears when the next command starts.
  - `needs-you` clears only through the agent's own hook events (UserPromptSubmit, PostToolBatch, Stop) or an interrupt. Viewing or focusing the tab never clears it (FEATURE-MAP PA-1).
- **R-ST-6 SHOULD** ⌘J focuses the next tab that needs you, across workspaces.

### 3.6 Inspector: Files

- **R-FS-1 MUST** The right inspector has two segments, **Files** and **Changes**. Toggle it with ⌥⌘0.
- **R-FS-2 MUST** Files is a tree rooted at the focused tab's current folder. It follows `cd` without stealing focus. The header shows the folder as a `~` path and a branch chip.
- **R-FS-3 MUST** Folders sort first. Ignored files follow the configured exclude rules, and gitignore rules are on by default. Rows show git decorations (modified, added, untracked, conflicted). File system changes update the tree, debounced.
- **R-FS-4 MUST** Keyboard and mouse:
  - Type-to-select, arrow keys, and Enter to open.
  - Context menu: Open, Reveal in Finder, Copy Path, Copy Relative Path, Open With Default App.
  - Dragging a file onto a terminal types its quoted path.
- **R-FS-5 MUST** The Files view has explicit states, each with a recovery action where one applies: loading, empty folder, folder missing (with Retry), unreadable, and no terminal focused.
- **R-FS-6 MUST** Images and PDFs open as a preview in the file pane.

### 3.7 Inspector: Changes

- **R-GIT-1 MUST** Changes lists the files changed in the focused tab's repository against HEAD: staged, unstaged and untracked.
  - Each file shows its status letter and +/- line counts.
  - A summary row shows the branch, the upstream (ahead/behind) and the totals.
  - A size warning appears above configurable thresholds (default: 1,500 changed lines or 50 files).
- **R-GIT-2 MUST** Selecting a file shows a read-only unified diff in the file pane, with Open File to edit.
- **R-GIT-3 MUST** Changes updates live on file changes, commits and branch switches.
- **R-GIT-4 LATER** Staging, committing, discarding hunks.

### 3.8 File pane: light native editor

- **R-ED-1 MUST** A TextKit 2 editor that can:
  - open, edit and save (⌘S)
  - show a dirty dot, and undo/redo
  - find and replace
  - go to line
  - toggle soft wrap and line numbers.
- **R-ED-2 MUST** Tree-sitter syntax highlighting for TypeScript, TSX, JavaScript, JSON, Rust, Swift, Python, Go, Markdown, YAML, TOML, shell, CSS, HTML and SQL. Other files open as plain text.
- **R-ED-3 MUST** A git gutter shows added, modified and deleted hunks against HEAD, updated on save and on file change.
- **R-ED-4 MUST** External changes reload a clean buffer silently. For a dirty buffer, Mapo offers "Keep Mine" or "Reload".
- **R-ED-5 MUST** Unsaved text is never lost:
  - Switching workspaces keeps editor state.
  - Quitting the app asks about unsaved files.
  - A crash leaves an autosaved recovery copy in the instance directory.
- **R-ED-6 MUST** Files over 8 MB, or binary files, open read-only or as "Open With Default App".
- **R-ED-7 SHOULD** Markdown preview toggle. Clicking a gutter hunk shows it inline.

### 3.9 Servers are ordinary tabs; ports and processes

- **R-SRV-1 MUST** Mapo detects servers:
  - A tab is **serving** when a process in its terminal session listens on a TCP port.
  - The rail row switches to the server icon and shows the port, for example `:4000`.
  - The pane header shows `localhost:PORT` with Open in Browser.
- **R-SRV-2 MUST** Detection is event-driven:
  - It scans when a command starts or ends (OSC 133), then with backoff while the command runs (1 s, 2 s, 5 s, then every 10 s).
  - It never scans idle tabs.
- **R-SRV-3 MUST** A serving command that exits with a non-zero code makes the tab `failed` ("exit N") until the next command starts. Attention rules apply.
- **R-SRV-4 MUST** Stop on a serving tab sends Ctrl-C to its foreground job.
- **R-SRV-5 MUST** Ports and processes:
  - The palette and `mapo ports` list the current user's TCP listeners with PID, executable name, port and owning tab.
  - `process stop PID --identity ID` re-checks the identity (PID, start time, executable) and sends SIGTERM to that one PID.
  - It never targets Mapo, the daemon or their ancestors, and it never escalates to SIGKILL.
  - Agents must pass `--force`.
- **R-SRV-6 LATER** Managed servers:
  - a saved command
  - auto-start with the workspace
  - a restart policy
  - restart, and logs kept across restarts
  - readiness patterns
  - discovery from `.claude/launch.json` and package.json scripts
  - dekit/mprocs import
  - sharing through portless or Tailscale.

### 3.10 Agent control plane: CLI, MCP, skill, events, activity

- **R-CTL-1 MUST** Commands are the feature boundary:
  - Every user-visible action is a daemon command with JSON arguments and a JSON result.
  - The app, the CLI, MCP, hooks and the automation surface call the same commands.
  - Command names and shapes are in [PROTOCOL.md](PROTOCOL.md).
- **R-CTL-2 MUST** `mapo` is a native Rust binary that starts in milliseconds. The v1 verbs are:
  - workspace: `list`, `new`, `rename`, `activate`, `delete`, `move`, `configure`
  - tab: `list`, `new`, `send`, `read`, `wait`, `run`, `ask`, `focus`, `close`, `interrupt`, `rename`, `move`
  - pane: `split`, `focus`, `close`
  - `status`, `file open`, `notify`, `ports`, `process stop`, `explorer refresh`, `explorer collapse`, `git changes`, `events --follow`, `activity`, `mcp`, `skill`, `ui …`, `attach`, `hook`, `daemon`

  Also `tab stop` and `pane equalize`.

  Verbs, flags and JSON shapes that also exist in the VS Code build stay compatible ([reference/vscode-build/COMMANDS.md](reference/vscode-build/COMMANDS.md)). Its server, setup, repo, action and mprocs verbs return with their features. Compatibility details:
  - The old kind names `terminal` and `claude` are accepted as aliases for `shell` and `agent`; output uses the new names.
  - `--tab-id ID` still selects a tab by ID.
  - `tab ask` now prints the agent's final reply (`last_assistant_message`) instead of its screen. This is a deliberate improvement.
- **R-CTL-3 MUST** Output and exit codes:
  - On a terminal, output is tables, or raw text for `tab read`, `tab run` and `git changes`.
  - When piped, or with `--json`, output is compact JSON.
  - Errors go to stderr with a nonzero exit.
  - Exit codes: 1 error, 2 usage, 5 needs you, 124 timeout. `tab run` exits with the command's own code.
- **R-CTL-4 MUST** Identity and guards:
  - The caller is identified by credentials (see PROTOCOL §3), never by arguments.
  - Names resolve in the caller's workspace.
  - Deleting a workspace, closing another tab and stopping a process need `--force` from agents.
  - Hook credentials can only report hook events for their own tab.
- **R-CTL-5 MUST** Events:
  - They are numbered and bounded, carry a daemon boot id, and can be replayed with `--after`. An expired cursor is an error.
  - They carry metadata only, never terminal contents or prompts.
- **R-CTL-6 MUST** The activity log records every mutating request from an agent or the automation surface: time, caller, command, target, outcome, and rejections. It is bounded and persisted, and readable with `mapo activity`. An activity view in the UI is LATER.
- **R-CTL-7 MUST** `mapo mcp` is a stdio MCP server built on the official `rmcp` crate, pinned. It has one typed tool per public v1 command (`mapo_workspace_list`, `mapo_tab_ask`, …), plus `mapo_events_wait` and the resource `mapo://skill`.
- **R-CTL-8 MUST** The `mapo` skill ships in the plugin. It explains names, verbs, waiting instead of polling, guards, and conventions. `mapo skill` prints it.
- **R-CTL-9 MUST** Wait and run semantics:
  - `tab wait --until idle` waits for the shell prompt, or for an agent that is idle or done.
  - On shell tabs, `--until TEXT` matches only output printed after the last `tab send` (or after the wait started), never the echoed command.
  - On agent tabs, it matches the rendered screen, because TUIs redraw in place; the prompt Mapo just sent never satisfies the wait (PA-14).
  - `tab run` requires shell integration and a non-busy tab. It returns `{exitCode, output, truncated, durationMs}`.

### 3.11 Persistence and sessions

- **R-PER-1 MUST** The daemon owns PTYs, state and scanners. The app is a client that can come and go.
- **R-PER-2 MUST** State lives in SQLite (WAL) in the instance directory: workspaces, tabs, layouts, file panes, agent session ids and the activity log. Settings live in `config.toml`, which is watched and hot-reloaded.
- **R-PER-3 MUST** When the daemon restarts, tabs come back from their definitions:
  - Shells restart in their last cwd.
  - Agents resume per R-AG-7.
  - Shell commands are never replayed.
  - Layout, order and names are preserved.
- **R-PER-4 MUST** Dev instances run the daemon in the foreground or spawned by the app. The installed app registers it as a login agent (SMAppService) at switch-over (M5).
- **R-PER-5 LATER** Upgrade the daemon without losing live sessions, by handing off file descriptors to the new binary.

### 3.12 Palette, menus and keyboard

- **R-KEY-1 MUST** ⌘K opens the palette. It fuzzy-searches workspaces, tabs (showing their state), recent files and commands.
- **R-KEY-2 MUST** Every command is reachable from the keyboard and appears in the native menu bar with its shortcut. The keyboard map is in UX §8.
- **R-KEY-3 MUST** Holding ⌘ shows ⌘1–⌘9 hints on the active workspace's tab rows.

## 4. Non-functional requirements

- **R-NF-1 MUST: performance budgets.** These are targets on an M-series Mac, measured with `mapo ui metrics` and `mapo debug stats` (see ENGINEERING §6).

  | Metric | Budget |
  |---|---|
  | Cold launch to first interactive frame, daemon already running | ≤ 400 ms |
  | Reattach and paint a workspace with 10 tabs | ≤ 150 ms |
  | Switch workspace to visible | ≤ 50 ms |
  | Keystroke to glyph, compared with plain Ghostty | ≤ +2 ms |
  | Idle CPU with 20 tabs open | app ≈ 0%, daemon < 0.5% |
  | Memory with 20 tabs and 10 visible | daemon ≤ 150 MB (2 MiB replay ring and 2,000-line emulator per tab), app ≤ 250 MB |

- **R-NF-2 MUST: lightweight.** No Electron, no Node at runtime, no web views in v1. Use few dependencies, each justified in ARCHITECTURE.md.
- **R-NF-3 MUST: reliability.**
  - No state loss on an app or daemon crash.
  - No blank screens: every error names the problem and the next step.
  - A failed action never leaves a half-applied change, such as a workspace switch cancelled halfway.
- **R-NF-4 MUST: security.**
  - Socket directory 0700 and socket 0600.
  - The peer uid is checked, and credentials are role-scoped.
  - No TCP listeners, and no tokens in logs, events or activity.
  - The app is unsandboxed with the hardened runtime.
  - It has usage-description strings, so tools run in terminals can request camera, microphone and other permissions.
- **R-NF-5 MUST: accessibility and drivability.**
  - Every control has a stable accessibility identifier (ENGINEERING §4) and a VoiceOver label that speaks the state.
  - Mapo respects Reduce Motion, Reduce Transparency and Increase Contrast.
- **R-NF-6 MUST: appearance.**
  - Liquid Glass for the rail and inspector, and opaque panes.
  - The default theme uses the Mapo Glass palette (UX §9), in dark and light.
  - No title bar: the traffic lights sit in the rail.

## 5. Engineering requirements, from day one

Summary; the details are in [ENGINEERING.md](ENGINEERING.md).

- **R-ENG-1 MUST** Mapo is auto-drivable. `mapo ui` exposes:
  - the accessibility tree
  - a semantic snapshot: layout, rail, and visible terminal text
  - window id and geometry, for pixel screenshots
  - clicking, pressing, typing, key chords and waiting
  - timing metrics.

  It works from the first milestone and needs no Accessibility permission.
- **R-ENG-2 MUST** Validation means driving the real app. Each milestone ships **drives**: scripted walkthroughs that use the app the way a person does and leave evidence (snapshots, screenshots, timings). Agents read the evidence and judge the UX. Unit tests exist only for pure logic.
- **R-ENG-3 MUST** Isolation:
  - Any number of instances run side by side, one per worktree or per drive, each with its own daemon, socket, data, logs and window title.
  - Nothing listens on TCP.
  - The installed apps and their data are never touched by dev work.
- **R-ENG-4 MUST** Parallel development:
  - Builds are per worktree: their own cargo target and Xcode derived data.
  - Build artifacts are cached between worktrees; GhosttyKit is downloaded once.
  - Module boundaries let several agents work at the same time.
- **R-ENG-5 MUST** Lightweight dev loop:
  - `just dev` starts the daemon and the app for this worktree's instance under mprocs.
  - Rebuilding the app does not kill the terminals, because the daemon keeps them.

## 6. LATER: designed for, not built in v1

The architecture leaves room for the three items the user chose, and for the rest of the known backlog.

| Item | What the architecture keeps ready |
|---|---|
| **Worktrees and branch operations** (chosen): new worktree per workspace or agent; switch to qa/stg/prod and pull; paired backend/frontend worktrees | Git identity per tab (repository root and worktree), git through the CLI in the daemon, tabs created in a folder |
| **PR and review panel** (chosen): the branch's PR, checks and comments; review with N agents and consolidate outside the repo | The inspector is segment-based; a `gh` adapter in the daemon; review fan-out uses agent tabs and `tab ask` |
| **Browser pane** (chosen): a WKWebView pane pointed at a detected server URL; agents get screenshots or DOM text through a mediated API that never exposes cookies or storage | Pane content is a typed enum (`tab`, `file`, `diff`, later `web`); server URLs come from detection |
| Managed servers (R-SRV-6) | Tab launch definitions already store `command` and `cwd` |
| Saved setups, repository membership, `.mapo/actions` with ⌃⌘1–9 pins, dekit/mprocs import | Workspace and tab definitions are plain rows; the command registry is extensible |
| Default file opener, replacing CotEditor | `file open` already routes to the right workspace |
| Agent messaging, handoff note plus fresh tab, background agent dashboard, rail-level approvals | Hooks already carry the needed events; `tab ask` exists |
| Other agent CLIs | An agent adapter interface in the daemon, with Claude as the first implementation |
| Activity view in the UI, pinning, hover cards | The data exists in v1 |

## 7. Out of scope

Ticket creation, mobile/VPN debugging helpers, Windows, and Linux (the Rust core stays portable where it costs nothing), plus cloud sync and multi-user.

## 8. Behavior contracts carried over from the VS Code build

The VS Code build learned these the hard way (see `git show mapo:docs/mapo/OVERNIGHT-PROGRESS.md`). They are requirements here too.

1. A tab whose launch fails keeps its definition, shows the reason, and retries on focus. Retries are serialized, and concurrent focus requests start exactly one process.
2. Switching workspaces never loses dirty editor text. Cancelling a switch leaves no partial state and no orphan workspace.
3. Clicking a file focuses the editor. Background terminal or status updates never steal focus or scroll the rail.
4. Deleting a workspace keeps the rail's scroll position and focuses the next row, not the far-away active tab.
5. `tab read` includes populated rows below the cursor, because Claude draws menus there, and drops trailing blank space.
6. `tab wait` patterns match only output after the last send, never the echoed command.
7. Stop appears only for working agents. An interrupt goes to the pane whose Stop was clicked, not to whichever pane has focus.
8. A name someone chose is both label and address. Unnamed tabs show native titles.
9. The explorer has explicit loading, empty, missing and unreadable states with recovery. Overlapping refreshes are superseded, and the last focused tab wins.
10. `file open` rejects folders, missing paths, broken links and unreadable files with a clear error, never a blank editor.
11. Tabs never inherit the parent's `CLAUDE_CODE_*` session markers.
12. Claude's trust and login dialogs are reported as needs-you and never answered by Mapo.
13. State events never carry terminal contents. The only hook payload Mapo keeps is `last_assistant_message` for `tab ask`.

**Accepted additions.** The 43 proposed additions in [FEATURE-MAP.md](FEATURE-MAP.md) §6.2 (PA-1 to PA-43) are v1 behavior contracts with the same force as this list. PA-8 and PA-9 are SHOULD. Where a PA refines a requirement above, the PA wins. Cite PAs by ID in commits and drives.

## 9. Open questions

These are for the user and do not block M0.

- Where terminal font and theme settings live: Mapo's `config.toml` only, or also reading `~/.config/ghostty/config`. The default is Mapo's config with Ghostty-compatible keys.
- Notifications while the app is closed. The default is none; the daemon only badges once the app runs. The alternative is a tiny notifier helper in the bundle.
- Whether ⌘J and hover cards make v1 (both SHOULD).
