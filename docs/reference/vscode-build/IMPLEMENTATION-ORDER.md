# Proposed Mapo implementation order

Status: the user approved the order and authorized milestone execution. Everyday agent use and dev-server control are the focus, with both direct commands and mprocs supported, direct commands first. Delivery 0 must be validated in the running app and committed before delivery 1 begins.

Based on the complete [feature research](FEATURE-RESEARCH.md), the updated [handoff](HANDOFF.md), the [v1 design](../superpowers/specs/2026-09-25-mapo-workspaces-design.md), and the behavior audit of 2026-09-25. All 33 research suggestions are accounted for below. F1 and F2 remain outside Mapo's scope.

## Delivered status

Reliability (0), everyday agent use (1), the CLI, direct-command servers (2), and MCP are committed with running-app reports. Delivery 3 now includes [reusable actions](ACTIONS-DELIVERY.md), [existing mprocs configs](MPROCS-DELIVERY.md), and [port/PID controls](PROCESS-CONTROLS-DELIVERY.md), each validated through agent commands and the UI.

The first mprocs adapter keeps per-process controls in its TUI. Typed per-process remote control needs a private upstream protocol; installed mprocs 0.9.6 exposes only unauthenticated TCP events. Config generation remains deferred. Product rename remains a separate final change. Delivery 4 now includes workspace/tab rail pinning and ordering plus saved launch setups through commands, CLI, MCP and UI. Optional named Git-root membership is also delivered, including repo-selected tabs and saved-setup persistence. Deliveries 5 onward have not started.

## Intended outcome

Mapo should become the daily home for parallel terminal and Claude work. A named workspace can contain backend, frontend, other repo tabs, dev servers, and adjacent file editors. It must remain useful without a repo or mandatory project folder.

The current code already gives each tab its own directory. Multi-repo work does not require replacing that model; the missing pieces are reusable setups, optional repo membership, tab roles, configurable commands, and reliable lifecycle handling.

The research is a prioritized requirements inventory. The existing approved spec and implementation plan cover v1 only. New subsystems need small, separate designs as they reach implementation.

## Recommended sequence

| Order | Deliverable | Research suggestions | Why here |
|---|---|---|---|
| 0 | Reliable workspace and editor behavior | A6, plus handoff and audit defects | Every later feature depends on correct ownership, switching, focus and restoration. |
| 1 | Everyday agent use | A7, B1, B2, B5 | Correct status and the work Claude identity address frequent daily needs without waiting for a larger subsystem. |
| 2 | Server tabs | C1, C6 | Start, stop, restart and inspect backend/frontend servers without leaving the workspace. |
| 3 | Existing process setups and reusable commands | A8, C2, C4 | Integrate mprocs, identify port conflicts and pin frequent actions after individual server control works. |
| 4 | Saved project setups and basic rail organization | A1, A2, A4, first part of A5 | Save the now-useful mix of agent, shell and server tabs; avoid making a full recipe system a prerequisite for daily use. |
| 5 | Repo awareness, worktrees and file routing | D1, D2, D3, D5, E3 | Uses project membership to show the right branch/diff, create isolated work, and route Finder/CLI file opens. |
| 6 | Agent continuity and coordination | B3, B4, B6, B7, remainder of A5 | Resume, handoff, messaging and dashboard all need a consistent identity and lifecycle for agent sessions. |
| 7 | PR and review workflow | B8, D6, D7, D8 | Builds on repo identity, changes summaries and managed agent sessions. |
| 8 | Browser and visual review | E1, E2 | Uses server URLs and requires a defined boundary between signed-in browsing and agent access. |
| 9 | Project bootstrap and environment conveniences | A3, C3, C5, D4 | These compose several earlier capabilities and vary substantially between projects. |

This order is about dependencies and user value, not numerical order in the research. Later releases may move earlier once their prerequisites exist.

## Cross-cutting: agent control

Mapo must be equally usable by a human and an agent running in one of its tabs. This is a binding requirement starting with deliveries 0 and 1, not a later dashboard feature.

### Commands are the feature boundary

Every operation has a named `mapo.*` workbench command in VS Code's existing registry. Commands accept JSON arguments and return JSON results; errors are explicit. Implement commands before UI, and have UI call those same commands. Stable tab names supplement IDs so agents can address tabs. Resolve ambiguous names explicitly rather than silently choosing a target.

The initial surface is workspace list/create/rename/delete/activate; tab list/create (`name`, `kind`, `cwd`, `command`, `role`)/send (`text`)/read (`lines`)/wait (`until: idle | pattern`)/focus/close; per-tab and per-workspace status; file open (`path`, beside terminal); and notify. Delivery 2 adds server start/stop/restart/logs/status. Status distinguishes running, needs input, idle and exited; managed Claude hooks additionally report turn completion.

### CLI, identity and transport

Ship the `mapo` CLI immediately after delivery 1, before server controls. Use the existing window-specific `VSCODE_IPC_HOOK_CLI` / extension-host CLI server channel, or an equivalent window-scoped local socket. Inject `MAPO_WORKSPACE_ID`, `MAPO_TAB_ID`, and the stable tab name into every tab's environment. Support JSON output with `--json` and nonzero exit codes on failure.

Examples:

```sh
mapo workspace new Obsess --json
mapo tab new --name fe-server --cwd ../frontend --cmd "pnpm dev" --role server
mapo tab send be-claude "API contract changed, see docs/contract.md"
mapo tab wait fe-server --until "ready on"
mapo tab read fe-server --lines 50
```

The channel is reachable only through this running window's terminals, with user-only permissions and caller identity. Do not expose a public network control endpoint. Deleting a workspace or closing a tab owned by another workspace/agent requires an explicit flag or human confirmation. Keep a visible activity log identifying the agent and the change.

### Events and extensions

`mapo events --follow` streams state changes, including attention requests, tab exit, server failure and workspace activation. Waiting must subscribe to events/output, not require polling loops. These events also support future messaging and dashboards.

Small user/agent scripts in a repo's `.mapo/actions/` and global `~/.mapo/actions/` are discoverable in the command palette and through `mapo run <action>`.

After delivery 2, `mapo mcp` exposes the same command handlers as typed MCP tools. Managed Claude launch automatically includes this MCP server using its settings/MCP configuration. Ship a short Mapo skill describing names, commands, events, permissions and conventions.

### Acceptance and sequence

Each feature is driven through its command API as well as the UI. After the CLI lands, it becomes the primary acceptance harness; Playwright over CDP remains the visual and screenshot check. Delivery 0 still gets its own running-app acceptance and commit before delivery 1.

The sequence is reliability and initial commands → managed agent hooks/commands → CLI, identity, events and activity log → direct-command servers → MCP and agent skill → mprocs and script actions. Transport guardrails ship with the transport, not afterward.

Full milestone acceptance: from a Claude tab, create an Obsess workspace containing backend/frontend Claude tabs and backend/frontend server tabs; wait for both servers to be ready, restart one, read logs, switch workspaces, and relaunch. Saved definitions and workspace identity must survive; restart policy must remain explicit.

## First deliveries

### 0. Make the current workspace reliable

- Give every user-created terminal a workspace owner, including stock new/split actions.
- Fix reload and multi-tab restart before promising saved setups.
- Preserve each workspace's file editors when switching; cancellation must never leave a partially switched workspace.
- Clear or update the explorer when the active workspace has no terminal.
- Ensure clicking a file focuses its editor and background terminal events do not take focus away.
- Fix shortcut conflicts and the folder input interaction; new tabs normally inherit the focused terminal's current folder.
- Refresh existing branch labels when the branch changes.
- Clear inherited Claude session markers in the development launcher.
- Give tabs that have not been relaunched a neutral state rather than "Exited".
- Replace misleading empty-state actions. Keep the product rename for a separate final delivery because changing the Electron app name can disrupt launch and test scripts.

Acceptance is behavioral: use two workspaces, several tabs and a dirty file; switch, cancel, close, reload and relaunch without crossing workspace boundaries or losing saved tabs/editors. Exact preservation of editor layout needs to be decided in this delivery's design.

### 1. Make agent tabs useful throughout the day

- A workspace default launch command, with per-tab override: `claude`, `claude-work`, or another configured command.
- Distinguish configured launch identity from the title reported by the running session.
- Status per agent tab, rolled up across the workspace; activity in an unfocused tab must still be visible.
- Launch managed Claude tabs with a small `--settings` file registering `UserPromptSubmit`, `Notification`, and `Stop` hooks that report working, needs-input, and done states to Mapo. Keep title parsing only as a fallback for Claude started by hand (idle titles begin with ✳; working titles use spinner characters).
- Discoverable shortcuts for creating and navigating tabs/workspaces and moving focus between terminal and editor.
- A visible interrupt action sends Escape (`\x1b`) and leaves the session available for follow-up, verified against the actual CLI. Continue launching via `runCommand` in the interactive shell so the `claude-work` zsh alias resolves.

Acceptance: keep personal and work agent tabs in separate folders, run work in an unfocused tab, see which needs attention, interrupt and redirect it, and return to the intended tab using the keyboard.

### 2. Control backend and frontend servers

- Create a named server tab with a working folder, command and optional URL.
- Keep its saved launch definition when the process exits; an exit must not erase the tab or its last failure.
- Show running, stopped and failed state. Do not claim the application is ready merely because a process exists.
- Start, stop and restart in place, retaining accessible logs and exit information. Restart must not create a duplicate process.
- Reach "restart backend and tail logs" from another tab in the same workspace.
- Persist server definitions through reload/relaunch. Specify process survival and restart policy in the design rather than treating a saved command as permission to replay arbitrary shell history.

Acceptance: run backend and frontend commands in separate folders, open their URLs, stop/restart one without affecting the other, observe a deliberate failure, inspect its logs, and verify workspace switching and relaunch behavior.

### 3. Integrate existing process setups

- Read existing mprocs configuration before adding configuration generation.
- A process has one owner. When mprocs owns it, Mapo should route actions through that owner instead of starting another copy.
- Expose port/PID information and targeted stop actions.
- Pin frequently used named commands and expose their shortcuts.

The user selected both direct commands and mprocs, with direct-command server tabs first and the mprocs adapter second.

## Scope boundaries for later deliveries

- **Saved setups are not session resume.** A2 recreates a tab arrangement and configured commands. B4 resumes a specific agent conversation. Store the information separately.
- **Saved commands are not automatic bootstrap.** A3's clone/install/env synchronization waits until project setup and command execution are stable. Ordinary terminal commands should not be rerun on restore just because they were typed previously.
- **Rail organization can ship in two parts.** Start A5 with reordering and pinning workspaces/tabs. Mixing independently addressable agent threads into the rail follows their model in delivery 6.
- **Managed Claude status uses hooks.** `UserPromptSubmit`, `Notification`, and `Stop` are the integration contract. Title parsing is the fallback only for manually started sessions.
- **Process controls should build on existing project tools.** Start by reading existing mprocs configuration and exposing defined start/stop/restart/log actions. Generate configuration after the supported shape is clear.
- **Git visibility precedes compound Git actions.** Deliver branch/diff visibility before checkout-and-pull and paired environment promotion. Operations must account for dirty files and other agents using the same working directory.
- **PR inspection precedes agent review orchestration.** Show PR/check/comment state first. Review fan-out uses the session model, keeps review output outside the repo, and then supports consolidation.
- **Browser access needs its own design.** Reusing VS Code's browser does not by itself satisfy the requirement to keep authentication tokens out of agent tools.
- **Core deletion is allowed, but not a prerequisite.** The updated handoff supersedes the old upstream-merge constraint. Remove old contributions when useful to the scoped change; a broad Copilot/chat removal should not delay the first usable release.

## Complete suggestion mapping

| ID | Preserved scope | Delivery |
|---|---|---|
| A1 | Several repos in a project workspace; aggregate status and changes | 4, with aggregate changes in 5 |
| A2 | Saved tab folders, kinds and startup commands | 4 |
| A3 | Clone, install root/subpackages and sync environment configuration | 9 |
| A4 | Quickly add/remove unrelated repos | 4 |
| A5 | Reorder and pin a rail containing workspaces, tabs and agent threads | 4 for workspaces/tabs; 6 for agent threads |
| A6 | File clicks focus the editor; explorer updates do not steal focus | 0 |
| A7 | Discoverable creation, navigation and terminal/agent shortcuts | 1 |
| A8 | Pinned one-key command actions | 3 |
| B1 | Per-tab status, workspace rollup and attention badge | 1 |
| B2 | Workspace/tab choice of Claude identity or launch command | 1 |
| B3 | Background agent dashboard with results and navigation | 6 |
| B4 | Resume after limits/restart with recorded progress | 6 |
| B5 | Interrupt and redirect without discarding the session | 1 |
| B6 | Handoff note and fresh Claude tab in the same folder/branch | 6 |
| B7 | Named tabs and explicitly addressed messages | 6 |
| B8 | Per-repo skills and CI conventions with run actions | 7 |
| C1 | Server status, URL, restart, logs and last failure | 2 |
| C2 | Read or generate mprocs configuration and expose processes | 3, reading first |
| C3 | Restart and share through Tailscale or portless | 9 |
| C4 | Identify and stop a process by port/PID | 3 |
| C5 | Simulator build/run/reboot/terminate and last failure | 9 |
| C6 | Restart backend and tail logs from any tab | 2 |
| D1 | Switch to an environment branch and pull | 5, after branch/dirty-state awareness |
| D2 | Per-tab branch and fuzzy picker with log preview | 5 |
| D3 | New worktree for a workspace | 5 |
| D4 | Create, verify and clean up paired environment worktrees | 9 |
| D5 | Per-repo/workspace changes summary and size warning | 5 |
| D6 | Branch PR, checks and comments | 7 |
| D7 | Multi-agent review and consolidation outside the repo | 7 |
| D8 | PR description, re-review and target-branch helpers | 7 |
| E1 | Workspace browser, server URL and controlled agent access | 8 |
| E2 | Dev-page screenshot comparison against a Figma link | 8 |
| E3 | Default file opener and mapo CLI with matching/Quick workspace routing | 5 |

## Selected focus

The user chose everyday agent use and dev-server control together. Deliveries 0 through 3 are the immediate focus. Bring forward only the setup fields they require: stable tab identity, role, display name, launch command and working folder. Complete saved workspace recipes stay in delivery 4.

Within delivery 1, implement launch-command/identity selection first, then per-tab attention and workspace aggregation, then interrupt/navigation polish. For delivery 2, establish process start/exit ownership and retained logs before adding restart and URL actions.

The first useful milestone is one project workspace with backend and frontend Claude tabs using the intended identity, accurate visible activity, and separate backend/frontend server tabs with restart and logs. Workspace switching, reload and relaunch must not corrupt that setup. mprocs support follows this direct-command flow.

Design and implement these as small deliveries rather than one large rewrite. Validate changes mainly in the running app, with occasional end-to-end coverage and small automated checks where they protect a distinct contract.

For delivery 0, reproduce the plain-terminal reload failure before editing. Validate two workspaces with backend/frontend tabs and an unsaved file: switch, cancel a switch, reload, quit/relaunch, rename, close tabs and delete workspaces. Capture each stage over CDP using Playwright CLI and include screenshots in the report. Finish and commit delivery 0 before starting agent-tab changes. This session owns code edits on `mapo`; the other session is limited to documentation.
