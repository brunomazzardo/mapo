# Mapo native: roadmap

One page for the user, as of 2026-09-28. [PLAN.md](PLAN.md) has the tasks and their acceptance, [REQUIREMENTS.md](REQUIREMENTS.md) the requirement IDs, and [PROGRESS.md](PROGRESS.md) where the work stands.

## Milestones

A milestone is done when its drive passes: a scripted walkthrough of the real app that leaves snapshots, screenshots and timings in `evidence/` ([ENGINEERING.md](ENGINEERING.md) §5). An agent-night is one overnight `/goal` run with up to five parallel workers in their own worktrees.

| Milestone | Goal | Key requirements | Exit: this drive passes | Size |
|---|---|---|---|---|
| **M0** Walking skeleton | The daemon owns the tabs. The app shows the rail and a Ghostty terminal served through `mapo attach`. Agents drive everything with `mapo` and `mapo ui` from the first day. | R-PER-1, R-TAB-5, R-TAB-6, R-TAB-10, R-CTL-1, R-ENG-1 to R-ENG-5 | `m0-skeleton`: a terminal survives quitting and relaunching the app and restarting the daemon; the workspace and tab are made through `mapo ui`; timings recorded | 1 to 1.5 nights |
| **M1** Daily core | The S2 rail, tiling panes, instant workspace switching, status words, the Files inspector, the file pane editor, ⌘K, the full keyboard map and Mapo Glass | R-WS-1 to R-WS-7, R-TAB-7 to R-TAB-12, R-LAY-1 to R-LAY-7, R-ST-1, R-ST-2, R-ST-5, R-FS-1 to R-FS-6, R-ED-1, R-ED-2, R-ED-4 to R-ED-6, R-KEY-1 to R-KEY-3, R-NF-5, R-NF-6 | `m1-daily`: the daily flow end to end; workspace switch p95 ≤ 50 ms, reattach ≤ 150 ms, launch ≤ 400 ms; unsaved text survives a crash | 2 to 3 nights |
| **M2** Claude and attention | The plugin through `CLAUDE_CODE_PLUGIN_DIRS`, hook-driven status, agent tabs with Stop, badges, notifications only when you can't see the tab, resume after a restart | R-AG-1 to R-AG-4, R-AG-6, R-AG-7, R-ST-3, R-ST-4, R-ST-6 | `m2-agents`: Working, Needs you and Done come from hooks and show in the rail, header and dock; resume works | 1 to 1.5 nights |
| **M3** Agent control plane | CLI parity with the VS Code build, guards and the activity log, `tab ask`, event replay, `mapo mcp` and the skill | R-CTL-2 to R-CTL-9, R-AG-5 | `m3-control`: an agent inside Mapo drives Mapo through the CLI and MCP; guards reject and log; `tab ask` returns replies | 1.5 nights |
| **M4** Servers, ports, Changes | Port detection in ordinary tabs, the ports and processes list with safe stop, and the Changes inspector with diff view and editor gutter | R-SRV-1 to R-SRV-5, R-GIT-1 to R-GIT-3, R-ED-3 | `m4-servers-changes`: a server row shows `:PORT` and turns Failed on a bad exit; Changes and the diff update live | 1 to 1.5 nights |
| **M5** Switch-over | Every performance budget, the installed app as instance `main` with a login agent, a daily-driver checklist, and retiring the VS Code build | R-NF-1, R-PER-4 | `m5-switch` on a Release build meets R-NF-1, and you sign off the checklist | 1 night plus sessions with you |

Total: about 8 to 10 agent-nights, plus your time in M5. The first night aims to finish M0 and start M1. M1 is the largest milestone because it holds most of what you touch every day.

## What you can do after each milestone

- **M0.** Open `just app` in `~/code/mapo-native`, make workspaces and shell tabs, and use a real Ghostty terminal. Quit the app or rebuild it, and every shell is still there when it comes back.
- **M1.** Spend a working session in it: split panes, jump between workspaces, browse the Files inspector, edit and save a file beside the terminal, reach anything with ⌘K. It looks like the design canvas.
- **M2.** Run Claude in tabs. The rail tells you which agent needs you or has finished, the dock badge counts them, and a notification arrives only when you can't see that tab. Agents come back after a daemon restart.
- **M3.** Let agents run Mapo: the `mapo` CLI and MCP tools create tabs, run commands, wait, read and ask other agents. Every mutating call they make lands in the activity log.
- **M4.** Start dev servers in ordinary tabs and see `:PORT` in the rail. Stop stray listeners safely, and review the branch's changes and diffs in the inspector.
- **M5.** Install it as your real Mapo, start it at login, and retire the VS Code build once the checklist holds.

## Switch-over from the VS Code build

The VS Code build stays your daily driver until native passes its checklist (DECISIONS D-18). The two apps never share bundle IDs, sockets or data, so you can go back at any point before phase 4.

| Phase | Starts when | What you do | What stays true |
|---|---|---|---|
| 1. Freeze | Now | Keep using `/Applications/Mapo.app` for everything. It gets blocker fixes only. | Native dev builds run as `dev-*` instances under `~/Library/Application Support/dev.mapo.app/`. They never read `~/.mapo`. |
| 2. Parallel use | M2 done, better after M3 | Run the native app from `~/code/mapo-native` with `just app`. Use it for one real workspace, Claude tabs included. There is no import, so you start fresh (D-19). | The VS Code build is still the daily driver. Friction you report becomes tasks. |
| 3. Daily driver | M5 tasks T5.2 and T5.3 | Install with `just install`: instance `main` in `~/Applications/Mapo.app`, with a login agent once you approve it. Work in it for at least three days using the checklist in PROGRESS.md. | The VS Code build stays installed as a fallback, and its data is untouched. |
| 4. Retire | After a clean week on native | Quit and archive the VS Code app and `~/.mapo`. Move native to `/Applications/Mapo.app`. | The branch `mapo` and `~/code/mapo` stay frozen. Nothing deletes them. |

## Later

These are designed for but not built in v1 (REQUIREMENTS §6). "Builds on" names what v1 already provides. "Slot" is the first milestone after M5 the item fits into; items in the same slot can run in parallel worktrees.

### The three you chose (D-17)

| Item | What it adds | Builds on | Slot |
|---|---|---|---|
| Worktrees and branch operations | A new worktree per workspace or agent; switching to qa, stg or prod and pulling; paired backend and frontend worktrees | Each tab knows its repository and worktree (M1). Git runs through the CLI in the daemon (M4). Tabs open in any folder. | M6 |
| PR and review panel | The branch's PR, checks and comments in a new inspector segment; review with several agents, consolidated outside the repo | The segment-based inspector (M1), a `gh` adapter in the daemon, and `tab ask` fan-out (M3) | M7 |
| Browser pane | A WKWebView pane pointed at a detected server URL. Agents get screenshots and page text through a mediated API that never exposes cookies or storage. | Pane content is a typed enum with room for `web` (M1). Server URLs come from detection (M4). | M8 |

The order follows your list. The PR panel and the browser pane don't depend on worktrees, so either can move up if it turns out to matter more in daily use.

### The rest of the backlog

| Group | Items | Builds on | Slot |
|---|---|---|---|
| Servers | Managed servers (R-SRV-6): a saved command, auto-start with the workspace, a restart policy, logs kept across restarts, readiness patterns, discovery from `.claude/launch.json` and package.json scripts, dekit/mprocs import, sharing through portless or Tailscale | Tab definitions already store the command and cwd; server detection (M4) | M9 |
| Workspace organization | Pinned workspaces (R-WS-8), saved setups, repository membership, `.mapo/actions` with ⌃⌘1 to ⌃⌘9 pins | Workspaces and tabs are plain rows, and the command table is extensible | M9 |
| Editor and git | Mapo as the default file opener instead of CotEditor; Markdown preview and inline hunks (R-ED-7); staging, committing and discarding hunks (R-GIT-4) | `file open` routing (M1), the Changes inspector and diff view (M4) | M6 for the opener, M7 for staging |
| Agents | Agent messaging, a handoff note plus a fresh tab, a background-agent dashboard, approvals from the rail, other agent CLIs through `AgentAdapter` | Hooks already carry the events (M2); `tab ask` exists (M3) | M8 |
| Visibility | An activity view in the UI, hover cards, ⌘J if it misses v1 | The activity log and state events (M3) | M6 |
| Reliability | Upgrading the daemon without losing sessions by handing PTY file descriptors to the new binary (R-PER-5); notifications while the app is closed, through a small helper | The daemon owns every PTY (M0) | M6 |
| Shells | bash and fish integration (R-TAB-5 SHOULD) | The zsh integration (M0) | Late M1 if cheap, else M6 |

## Risks that could move the schedule

| Risk | Where it bites | What happens instead |
|---|---|---|
| The prebuilt GhosttyKit won't link or render | M0 | After a 2 h timebox, SwiftTerm renders the same `mapo attach` sessions. Building GhosttyKit with Zig becomes a later task (PLAN T0.8). |
| Replaying raw bytes on reattach leaves artifacts in full-screen programs | M0, M1 | The daemon renders its emulator grid instead (PLAN T0.6). |
| Claude Code changes hooks or plugin loading | M2, M3 | A version gate, a `--plugin-dir` fallback, and matcher strings kept in config. A drive with real Claude runs every milestone. |
| The daemon misses its memory budget with 20 busy tabs | M5 | Smaller replay buffers and emulator scrollback, measured before and after (ENGINEERING §6). |
| A step needs you: Screen Recording, notification permission, login items, a Claude login | Any | The agent keeps working on snapshots and synthetic paths, and lists the step under "Needs the user" in PROGRESS.md. |

## Non-goals

These stay out of v1 (REQUIREMENTS §1.2 and §7):

- Extensions, LSP, a debugger, or a VS Code-grade editor.
- Agent CLIs other than Claude Code, such as Codex, Gemini or opencode. The adapter seam stays.
- Managed server definitions. Servers are ordinary tabs that Mapo detects.
- Importing workspaces from the VS Code build.
- Sandboxing, signing for distribution, notarization and auto-update. Mapo is built locally for one person.
- Web views of any kind; the browser pane waits for M8.
- Accounts, onboarding, telemetry, cloud sync and multiple users.
- Windows and Linux. The Rust core stays portable where that costs nothing.
- Ticket creation, and mobile or VPN debugging helpers.
