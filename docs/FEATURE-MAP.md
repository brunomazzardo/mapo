# Mapo native: feature map of the VS Code build

Status: reference for M0 to M5, written 2026-09-28. This document maps the frozen VS Code build of Mapo onto the native design. Use it to find the old code behind a requirement, to port logic that already works, and to avoid relearning old bugs. [REQUIREMENTS.md](REQUIREMENTS.md), [ARCHITECTURE.md](ARCHITECTURE.md) and [PROTOCOL.md](PROTOCOL.md) win over anything written here. Frozen copies of the old command API, research, delivery order, overnight log and skill are in [reference/vscode-build/](reference/vscode-build/README.md).

The VS Code build is branch `mapo` at commit `a7bc6c9e73e`, checked out at `~/code/mapo`. That checkout is the user's daily driver. Read it, and never edit, build or check out anything there. Every line reference in this document, such as `L117-152`, is at commit `a7bc6c9e73e`. Section 7 has the commands.

Contents:

1. Legend
2. Feature map
3. Native v1 features with no VS Code counterpart
4. Code map
5. Port notes
6. Behavior-contract check, with the proposed additions
7. How to read old code

## 1. Legend

- Source paths are relative to `src/vs/workbench/contrib/mapo/` unless they start with `src/`, `scripts/`, `extensions/`, `build/` or `product.json`. "core" marks a VS Code file outside the contribution that Mapo edited.
- Status values:
  - `v1`: in native v1 with the same behavior.
  - `v1-changed`: in native v1 with a different mechanism or behavior. The cell says what changed.
  - `later`: designed for, not built in v1 (REQUIREMENTS §6).
  - `dropped`: not coming back. The cell says why.
- Native homes are the crates of ARCHITECTURE §3.1 (`mapo-protocol`, `mapo-instance`, `mapo-core`, `mapo-term`, `mapo-agent`, `mapo-proc`, `mapo-git`, `mapo-mcp`, and `crates/mapo` for the binary), the Swift modules of ARCHITECTURE §4.1 (`MapoProtocol`, `MapoClient`, `MapoTerminal`, `MapoEditor`, `MapoUI`, `MapoAutomation`), the app target `app/Mapo/`, and the repo folders `plugin/`, `resources/` and `drives/` of ARCHITECTURE §5.
- Names that changed between the builds:

  | VS Code build | Native |
  |---|---|
  | tab kinds `terminal`, `claude` | `shell`, `agent` |
  | automatic names `terminal-N`, `claude-N` | `terminal-N`, `agent-N` (R-TAB-3) |
  | `MAPO_CONTROL_TOKEN` (per tab) | `MAPO_TOKEN` |
  | `MAPO_AGENT_TOKEN` (per agent launch) | `MAPO_HOOK_TOKEN` (per tab) |
  | one control socket per VS Code window, found through `MAPO_CLI_SOCKET_FILE` | one socket per instance, `<runtime dir>/<instance>.sock` |
  | workbench command ids such as `mapo.tab.create` | protocol methods such as `tab.create` |
  | raw status `needs-input`, `exited`, `unstarted` | vocabulary `needs-you`, `failed`, `stopped`, `idle` |

## 2. Feature map

### 2.1 Workspaces

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Create workspace | `browser/mapoCommands.ts` L183-191; `browser/mapoActions.ts` L114-136; `browser/mapoWorkspaceService.ts` L231-237 | Creates a folderless workspace named with the first free "Workspace N", no prompt. The UI action also opens one shell tab. `workspace new` over CLI or MCP creates it empty. | `mapo-core` `workspace.create`; `app/Mapo` menu ⇧⌘N; `MapoUI` `rail.newWorkspace` | R-WS-1 | v1 |
| Rename workspace | `browser/mapoActions.ts` L176-204; `browser/mapoWorkspaceService.ts` L239-245; guard `browser/mapoControlService.ts` L137 | Trimmed, non-empty name. Names may repeat; an ambiguous name needs the ID. | `mapo-core` `workspace.rename`; `MapoUI` inline rename | R-WS-1 | v1-changed. Inline rename in the rail replaces the modal name card. |
| Delete workspace | `browser/mapoActions.ts` L239-266; `browser/mapoWorkspaceService.ts` L318-354; guard `browser/mapoControlService.ts` L139 | The UI always confirms, naming the tab count. Agents need `--force`. Unsaved files are resolved first and Cancel keeps everything. Deleting the active workspace activates the next one. | `mapo-core` `workspace.delete`; `MapoUI` sheet with `dialog.*` ids | R-WS-1, R-CTL-4, §8.4 | v1-changed. Confirms only when a tab runs a foreground program. |
| Switch workspace | `browser/mapoWorkspaceService.ts` L356-426; `browser/mapoEditorSessions.ts` | Detaches the old workspace's terminals, closes its file editors, restores the target's saved editor layout. Dirty files prompt Save, Don't Save or Cancel; Cancel restores the old layout. Processes keep running. | `mapo-core` `workspace.activate` and layouts; `MapoUI` split tree | R-WS-3, R-LAY-1, R-ED-5, §8.2, R-NF-1 | v1-changed. The app keeps every workspace's panes and editors alive, so a switch never prompts and must take at most 50 ms. |
| Next and previous workspace | `browser/mapoActions.ts` L268-301 | ⌃⌘↓ and ⌃⌘↑ cycle in rail order. | `app/Mapo` menus calling `workspace.activate` | R-KEY-2 | v1 |
| Reorder workspaces | `browser/mapoWorkspaceService.ts` L305-316; `browser/mapoCommands.ts` L199-205; `browser/mapoActions.ts` L219-237 | `move --index` is zero-based within the pinned or unpinned group. An invalid index fails without changing anything. Context menu Move Up and Move Down. | `mapo-core` `workspace.move`; `MapoUI` rail drag | R-WS-2 | v1-changed. Drag reorder; no pin groups. |
| Pin workspaces | `browser/mapoWorkspaceService.ts` L293-303; `browser/mapoCommands.ts` L192-198; `browser/mapoActions.ts` L206-217 | Pinned workspaces come first; pinning appends to the end of the pinned group. | none in v1 | R-WS-8 | later |
| Workspace agent command | `browser/mapoWorkspaceService.ts` L286-291; `browser/mapoCommands.ts` L215-220; `browser/mapoActions.ts` L97-105, L323-343 | Default command for agent tabs, such as `claude` or `claude-work`; a tab's own command overrides it. The picker offers claude, claude-work and a custom command. | `mapo-core` `workspace.configure`; `mapo-agent` launch | R-WS-6 | v1 |
| Workspace state and summary | `browser/mapoStatus.ts` L87-105; `browser/mapoWorkspaceService.ts` L974-984; `browser/mapoWorkspacesView.ts` L108-141 | The most urgent tab state wins, but a server that is simply up never does. Summaries read "fe failed", "agent needs you", "2 working". Badges count needs-you and failed tabs. The row shows the branch, or the folder outside git. | `mapo-core::status` fields `state`, `summary`, `attentionCount`, `branch`; `MapoUI` rail row | R-WS-4, R-WS-5, R-WS-7, R-ST-2 | v1-changed. The S2 row shows a dot, the needs-you badge and the branch. The `statusTab`, `statusTabName` and legacy `status` fields are gone. |

### 2.2 Tabs and terminals

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Tab kinds and creation | `browser/mapoCommands.ts` L242-275; `browser/mapoWorkspaceService.ts` L458-495, L687-747; `browser/mapoActions.ts` L46-95, L138-174, L303-321 | Terminal or Claude tab in a folder. ⌘T and ⇧⌘T use the current tab's detected folder; "In Folder…" asks, with the full path selected. The folder must exist and be absolute. Commands run through the interactive shell, so aliases resolve. | `mapo-core` `tab.create`; `mapo-term` spawn and env; `app/Mapo` menus | R-TAB-1, R-TAB-2, R-TAB-4 | v1-changed. Kinds are `shell` and `agent`. The daemon types the command after the first prompt (OSC 133;A) instead of VS Code's `runCommand`. |
| Tab names and titles | `common/mapoWorkspace.ts` L76-78; `browser/mapoWorkspaceService.ts` L497-503, L986-996, L1097-1109; `browser/mapoCommands.ts` L261-263, L283-290; core `terminalEditorInput.ts` | The name is the address: unique in the workspace, no spaces or slashes. A chosen name is `labeled` and is also the title. Unnamed tabs show the live title without Claude's status glyph, and "Claude" for its bare version-number title. | `mapo-core` name, labeled, title; `mapo-term` OSC 0/2; `mapo-agent` glyph strip | R-TAB-3, §8.8 | v1. Automatic agent names become `agent-N`. Details in §5.7. |
| Rename tab | `browser/mapoActions.ts` L512-536; `browser/mapoCommands.ts` L283-290 | Name card prefilled from the title turned into a valid name. Duplicate and invalid names are rejected in the card. | `mapo-core` `tab.rename`; `MapoUI` inline rename, ⌥⌘R | R-TAB-3 | v1-changed. Inline rename. |
| Tab order, next and previous | `browser/mapoWorkspaceService.ts` L429-439, L645-658; `browser/mapoCommands.ts` L227-237, L291-297; `browser/mapoActions.ts` L389-398, L573-589 | Saved order drives ⇧⌘[ and ⇧⌘] and the editor tab order. | `mapo-core` `tab.move`; `MapoUI` rail drag | R-TAB-8, R-KEY-2 | v1-changed. Drag reorder; the order also drives ⌘1 to ⌘9. |
| Tab pinning | `browser/mapoWorkspaceService.ts` L631-643; `browser/mapoCommands.ts` L276-282 | Pinned tabs come first in their workspace. | none | none | dropped. Not in native scope; it could return with R-WS-8. |
| Go to tab | `browser/mapoActions.ts` L400-413 | ⌘P picker over every tab, with state and folder. | `MapoUI` palette ⌘K | R-KEY-1 | v1-changed. Part of the ⌘K palette. |
| Close tab | `browser/mapoWorkspaceService.ts` L660-670, L893-908; `browser/mapoCommands.ts` L303-312; guard `browser/mapoControlService.ts` L140-142 | The UI confirms only across workspaces. Agents need `--force` for other tabs; closing your own tab is always allowed. The workspace's active tab falls back to its first tab. | `mapo-core` `tab.close` | R-TAB-7, R-CTL-4 | v1-changed. Confirms only while a foreground program runs. |
| Terminal hosting | `browser/mapoWorkspaceService.ts` L364-454, L781-853; core `terminalService.ts`, `terminalInstance.ts`, `terminalEditor.ts` | VS Code terminal editors in editor groups, detached and reattached on switch. Processes die with the window. | `mapo-term` PTY, emulator, ring; `mapo attach`; `MapoTerminal` `GhosttySurfaceView` | R-TAB-6, R-TAB-10, R-PER-1 | v1-changed. The daemon owns the PTYs, so quitting, crashing or rebuilding the app keeps every tab. |
| Launch diagnostics and retention | `browser/mapoWorkspaceService.ts` L687-779, L874-891; `browser/mapoStatus.ts` L57; `browser/mapoWorkspacesView.ts` L241; core `terminalInstance.ts` | A failed launch keeps the tab, shows "Couldn't start" with a path-specific reason, and retries on focus through one serialized queue. Success clears the error. | `mapo-core` launchError and single-flight retry; `mapo-term` cwd check; `MapoUI` row | R-TAB-9, §8.1 | v1. Details in §5.8. |
| Shell status | `browser/mapoWorkspaceService.ts` L555-593, L813-819, L1011-1033 | Running while shell integration reports an executing command or a command Mapo just sent; idle at the prompt. A BEL marks the tab needs-input until it is focused. | `mapo-term` OSC 133 and BEL; `mapo-core::status` | R-TAB-5, R-TAB-11, R-ST-1 | v1-changed. Adds done and failed for commands that ran 30 s or more. BEL handling is unspecified; see PA-9. |
| Tab environment | `scripts/mapo.sh` L18-23; `browser/mapoControlService.ts` L83-89 | The dev launcher unsets `CLAUDE_CODE_*` and `CLAUDECODE`. Every terminal gets `MAPO_WORKSPACE_ID`, `MAPO_TAB_ID`, `MAPO_TAB_NAME`, `MAPO_CONTROL_TOKEN`, `MAPO_CLI_SOCKET_FILE`, and PATH with a generated `mapo` launcher first. | `mapo-term` environment builder | R-TAB-4, §8.11 | v1-changed. The daemon strips markers per tab and sets `MAPO_INSTANCE`, `MAPO_TOKEN`, `MAPO_HOOK_TOKEN` and the bundled `mapo` first on PATH. |

### 2.3 Claude agent tabs

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Claude integration | `browser/mapoAgentSessions.ts` L54-115; core `extHostExtensionService.ts` (`mapo.internal.cliInfo`) | For each agent launch whose command is `claude` or `claude-work`, writes a `--settings` file with 10 hooks, a Node reporter that posts `{event, scope}` to the window socket, an `--mcp-config` for `mapo mcp`, and an `--add-dir` holding the skill. | `plugin/` hooks.json, .mcp.json, skills/mapo; `mapo-agent` plugin env and version gate; `mapo hook` | R-AG-1, R-AG-2 | v1-changed. The plugin reaches every tab through `CLAUDE_CODE_PLUGIN_DIRS`, so Claude typed by hand in a shell tab reports too. |
| Hook status machine | `browser/mapoAgentSessions.ts` L117-182; core `extHostCLIServer.ts` (`mapoHook`) | Scoped attention, subagent tracking, interrupt suppression, optimistic Working with a 6 s revert. | `mapo-agent` status machine behind `hook.report` | R-AG-3 | v1. Port nearly verbatim; see §5.1. |
| Title fallback | `browser/mapoAgentSessions.ts` L199-208; `browser/mapoWorkspaceService.ts` L1038-1044 | ✳ means idle and a spinner glyph means running. Used only when no hooks arrived. | `mapo-agent` | R-AG-3 | v1 |
| Trust and login dialog | `browser/mapoWorkspaceService.ts` L820-830, L1040, L1048-1056 | While hooks are not connected, 250 ms after output, scans the last 40 rows for "Enter to confirm" or "trust this folder" and reports needs-you. Never answers it. | `mapo-agent` screen matcher on the emulator grid; patterns in `config.toml` `[agent] trust-dialog-patterns` | R-AG-3, §8.12 | v1 |
| Interrupt and Stop | `browser/mapoWorkspaceService.ts` L604-612; `browser/mapoCommands.ts` L222-226; `browser/mapoActions.ts` L345-364; `browser/mapoStartup.ts` L33-41; `browser/mapoStatus.ts` L123-128 | ⇧⌘X or the group's Stop sends Escape and records the interrupt. Stop shows only for a working agent and targets its own editor group, not the focused one. | `mapo-agent` `tab.interrupt`; `MapoUI` pane header `pane.stop:<tabName>` | R-AG-4, R-LAY-6, §8.7 | v1 |
| Session resume | `node/mapoProcesses.ts` L66-116; `browser/mapoWorkspaceService.ts` L694-701, L736-737, L795-796, L924-962; `common/mapoWorkspace.ts` L30-40 | 3 s after agent activity, finds the Claude process under each tab's shell, reads `<configDir>/sessions/<pid>.json`, and keeps `{id, command, cwd}` when a transcript exists. Relaunch runs `<command> --resume <id>` in that cwd. Claude exiting on its own forgets the session. | `mapo-agent` session id from SessionStart; `mapo-core` `agent_sessions` | R-AG-6, R-AG-7, R-PER-3 | v1-changed. The id comes from the SessionStart hook, not a pid-file scan. Resume is SHOULD. See PA-6 to PA-8. |
| `tab ask` | `browser/mapoCommands.ts` L412-461; `common/mapoAgentReply.ts` | Sends a prompt, confirms UserPromptSubmit, waits for the turn to end, then cuts a reply from the screen. | `mapo-agent` ask waiter; `mapo-core` | R-AG-5 | v1-changed. The reply is the Stop hook's `last_assistant_message`, and a busy target is waited for instead of rejected. See §5.5. |

### 2.4 Status and attention

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Status vocabulary | `browser/mapoStatus.ts`; `test/browser/mapoStatus.test.ts` | Eight states in priority order, labels ("Working" for agents, "Running" for commands), qualifiers such as "exit 1", phrases and color tones. | `mapo-core::status`, a pure function with unit tests; `MapoUI` colors | R-ST-1, R-ST-2 | v1. See §5.2. |
| Attention marks | `browser/mapoWorkspaceService.ts` L855-872; core `terminalEditorInput.ts` `getIcon`; `browser/mapoWorkspacesView.ts` L121-131, L150-155 | Editor tabs and rail rows get a mark only for needs-you or failed. Workspace rows count them. | `MapoUI` rail and pane header; `app/Mapo` dock badge | R-ST-2, R-ST-3 | v1-changed. Adds the dock badge. |
| Notifications | `browser/mapoCommands.ts` L483-486 | `notify` shows an in-app toast. State changes never notify. | `app/Mapo` with `UNUserNotificationCenter`; `notify` routed to the app | R-ST-4, R-CTL-2 | v1-changed. macOS notifications when the tab is not visible. |
| Hover cards | `browser/mapoStatus.ts` L108-120; `browser/mapoWorkspacesView.ts` L104, L140, L156 | Hover shows name, state, session title, URL, folder and the last lines of a failure. | `MapoUI` popover | REQUIREMENTS §9 (SHOULD) | later |

### 2.5 Files, editor and git

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Files inspector | `browser/mapoExplorerView.ts`; `browser/mapoExplorerDataSource.ts`; `browser/mapoExplorerActions.ts`; `test/browser/mapoExplorerDataSource.test.ts` | Tree rooted at the focused terminal's cwd with a `~` path row. Folders first, `files.exclude`, git decorations, explicit states with Refresh, parent-folder watch, generation-guarded reads, type-to-select, and files open beside the terminal. | `mapo-git` `fs.list` and `fs.watch` with the `ignore` crate; `MapoUI` inspector Files | R-FS-1 to R-FS-6, §8.9 | v1-changed. Listing and watching move to the daemon; gitignore rules are on by default; the context menu and drag-to-terminal are new. |
| Explorer refresh and collapse commands | `browser/mapoCommands.ts` L467-474; `browser/mapoExplorerView.ts` L274-329 | Act on the folder currently shown. Return `{path, state}`, or `superseded` when focus changes mid-read; an unreadable folder is an error. | `explorer.refresh`, `explorer.collapse` routed to `MapoUI` | R-CTL-2, §8.9 | v1 |
| File open | `browser/mapoWorkspaceService.ts` L531-553; `browser/mapoCommands.ts` L475-482; `browser/mapoExplorerView.ts` L376-378 | Validates before any UI change: folders, missing paths, broken links, non-regular and unreadable files fail. Serialized with workspace switches. Opens beside the terminal and focuses the editor. | `mapo-core` `file.open`; `MapoUI` file pane; `MapoEditor` | R-LAY-5, §8.3, §8.10 | v1 |
| File editors per workspace | `browser/mapoEditorSessions.ts`; `browser/mapoWorkspaceService.ts` L156-160 | Serializes each workspace's editor layout, editors, view state and selection, and restores them on switch and reload. | `mapo-core` `file_panes` and layouts; `MapoEditor` recovery copies | R-LAY-5, R-ED-1, R-ED-5 | v1-changed. One native file pane per workspace with a recent-files list. |
| Image preview | VS Code image editor, validated in OVERNIGHT checkpoint 7 | Images open beside the terminal. | `MapoEditor` preview | R-FS-6 | v1-changed. Native image and PDF preview. |
| Git branch | `browser/mapoGitBranch.ts`; `test/browser/mapoGitBranch.test.ts`; refresh at `browser/mapoWorkspaceService.ts` L1059-1069 | Walks up to `.git`, follows a worktree's `gitdir:` file, and shows a detached HEAD as a 7-character sha. Cached per folder and refreshed on focus and when a command finishes. | `mapo-git` | R-WS-5, R-FS-2 | v1 |
| Git decorations | VS Code git extension through `fileDecorations` at `browser/mapoExplorerView.ts` L65 | Modified and untracked colors in the tree. | `mapo-git` status cache feeding the `git` field of `fs.list` | R-FS-3 | v1-changed. The daemon runs the git CLI. |
| Home as `~` | core `src/vs/base/common/labels.ts`; `node/mapoCliFormat.ts` L12-16 | The home folder itself shows as `~`, paths under it as `~/…`. | `MapoUI` and `crates/mapo` formatting | R-FS-2 | v1 |

### 2.6 Agent control plane

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Command boundary | `common/mapoControl.ts` L7-18; every handler in `browser/mapoCommands.ts` | Workbench commands with JSON arguments and results. 50 public commands; internal and UI-only commands never cross the transport. | `mapo-protocol` methods; `mapo-core` dispatch | R-CTL-1 | v1-changed. JSON-RPC methods instead of workbench command ids. |
| Credentials, caller and guards | `browser/mapoControlService.ts` L83-161; core `extHostCLIServer.ts` | Per-terminal token; names resolve in the caller's workspace; an omitted tab means the caller's own tab; `force` for deleting workspaces, closing other tabs, stopping processes and deleting setups. | `mapo-core` credentials and guards; `mapo-instance` tokens | R-CTL-4, R-NF-4 | v1-changed. Role credentials `tab`, `hook` and `app` on the instance socket. See §5.10. |
| Events | `browser/mapoControlService.ts` L170-215; `node/mapoCli.ts` L77-85; `node/mapoMcp.ts` L88-92 | Ring of 1,000 events per window, derived by diffing state on every change; long-poll with a cursor; an expired cursor is an error. | `mapo-core` event ring; `events.subscribe`, `events.wait` | R-CTL-5 | v1-changed. Typed events emitted at mutation points, a 10,000-event ring and a `bootId`. |
| Activity log | `browser/mapoControlService.ts` L163-168; `browser/mapoActivityView.ts` | Last 200 mutating agent requests with time, caller name, command, target and outcome, persisted in storage and shown in a panel. | `mapo-core` `activity` table | R-CTL-6 | v1-changed. 5,000 rows including rejections and automation calls; the UI view is later. |
| CLI | `node/mapoCli.ts`; `node/mapoCliFormat.ts`; `node/mapoCliTransport.ts`; `src/mapo-cli.ts`; core `extHostExtensionService.ts` launcher | Node script run by Electron in Node mode through a generated per-window launcher. Tables on a terminal, JSON when piped, exit 1 on errors, 5 for needs-you, the command's own code for `tab run`. | `crates/mapo` with clap | R-CTL-2, R-CTL-3 | v1-changed. Native Rust binary; adds exit 2 for usage and 124 for timeouts; server, setup, repo, action and mprocs verbs are later. See §5.9. |
| MCP | `node/mapoMcp.ts` | TypeScript SDK stdio server with one strict tool per public command (51 tools with `mapo_events_wait`), the `mapo://skill` resource and the skill as instructions. Cancellation reaches the socket request; closing stdin exits. | `mapo-mcp` on rmcp | R-CTL-7 | v1-changed. rmcp, schemas generated from protocol types, v1 tool set. |
| Skill | `common/mapoSkill.ts`, copied to [reference/vscode-build/SKILL.md](reference/vscode-build/SKILL.md) | One text for Claude (through `--add-dir`), `mapo skill` and `mapo://skill`. | `plugin/skills/mapo/SKILL.md`; `mapo skill` | R-CTL-8 | v1-changed. Rewrite it for native verbs in T3.6. |
| `tab send`, `read`, `wait`, `run` | `browser/mapoWorkspaceService.ts` L555-602; `browser/mapoCommands.ts` L119-165, L313-411 | Input, screen reads, waits for idle or a pattern, one-shot commands with exit codes. | `mapo-term` grid and OSC 133; `mapo-core` waiters | R-CTL-9, §8.5, §8.6 | v1. See §5.3 and §5.4. |
| `status` | `browser/mapoCommands.ts` L463-466 | Returns the named tab, or the workspace with its aggregate state. | `crates/mapo` over `tab.list` and `workspace.list` | R-CTL-2 | v1 |

### 2.7 Servers, ports and processes

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Managed server tabs | `browser/mapoServerSessions.ts`; `browser/mapoCommands.ts` L495-544; `browser/mapoActions.ts` L366-387, L415-443, L538-549; `common/mapoWorkspace.ts` L11-16 | Tabs with `role: server`, a saved foreground command, auto-start, start, stop and restart serialized per tab, 256 KB of logs, last failure, and a URL from config or output. | none in v1 | R-SRV-6 | later. v1 detects servers in ordinary tabs instead (R-SRV-1 to R-SRV-4). |
| Server URL | `browser/mapoServerSessions.ts` L78-83, L247-253 | Takes the first `http(s)://` in output, maps `0.0.0.0` to `localhost`, rejects credentials. | `mapo-proc` port; `MapoUI` pane header `localhost:PORT` | R-SRV-1 | v1-changed. The URL comes from the detected listening port. |
| Ports and processes | `node/mapoProcesses.ts` L14-64; `browser/mapoCommands.ts` L584-623; `browser/mapoActions.ts` L490-503; `common/mapoProcesses.ts` | Current-user TCP listeners through `lsof` and `ps`, an identity hash, the owning tab by process ancestry, SIGTERM to one verified PID, and a palette picker with Focus Owning Tab and Stop Process. | `mapo-proc` with libproc and `listeners`; `MapoUI` palette | R-SRV-5 | v1-changed. No `lsof` or `ps`; no routing through a server or mprocs owner. See §5.6. |

### 2.8 Deferred subsystems

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Reusable actions | `browser/mapoScriptActions.ts`; `browser/mapoActions.ts` L445-475 | Scripts in `.mapo/actions/` and `~/.mapo/actions/`, pins on ⌃⌘1 to ⌃⌘9, one palette entry per script. | none in v1 | REQUIREMENTS §6 | later |
| mprocs projects | `node/mapoMprocsConfig.ts`; `common/mapoMprocs.ts`; `browser/mapoCommands.ts` L550-582; `browser/mapoActions.ts` L477-488 | Reads mprocs YAML safely, including `$select: os`, and opens one owner tab per config. | none in v1 | R-SRV-6, REQUIREMENTS §6 | later |
| Saved setups | `browser/mapoSetups.ts`; `browser/mapoSetupActions.ts`; `common/mapoSetups.ts`; `browser/mapoWorkspaceService.ts` L255-284 | Whitelisted launch snapshots. Opening validates every folder first and uses fresh IDs. | none in v1 | REQUIREMENTS §6 | later |
| Repository membership | `browser/mapoRepositories.ts`; `browser/mapoRepositoryActions.ts`; `common/mapoRepositories.ts`; `browser/mapoWorkspaceService.ts` L247-253 | Named Git roots per workspace and `tab new --repo NAME`. | none in v1 | REQUIREMENTS §6 | later |

### 2.9 Chrome and UI

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Rail | `browser/mapoWorkspacesView.ts`; `browser/media/mapo.css` L6-88; `browser/mapo.contribution.ts` L52-90 | One list of workspace rows (30 px) and the active workspace's tab rows (26 px). Marks, keyed in-place refresh, scroll and focus rules, context menus, and hover actions: Stop, Start, Interrupt, Restart, Open in Browser, Close Tab. | `MapoUI` rail on `NSOutlineView` | R-WS-4, R-ST-2, R-KEY-3, §8.3, §8.4 | v1-changed. S2 rows at 26 and 24 px, dots and words, hold-⌘ hints and drag reorder. Row actions move to the context menu and the pane header. |
| Name dialog | `browser/mapoNameDialog.ts`; `browser/media/mapo.css` L154-294 | Centered card with a title, a line on what the name is for, a validated field, Cancel and Save. | `MapoUI` inline rename | R-WS-1, R-TAB-3 | v1-changed. Inline rename; no modal. |
| Glass chrome and theme | `browser/media/mapoGlass.css`; `extensions/theme-defaults/themes/mapo-glass.json`; core `workbenchThemeService.ts` | Backdrop gradient with radial glows, frosted overlays and card shadows; Mapo Glass is the default dark theme. | `MapoUI` theme; `app/Mapo` window | R-NF-6 | v1-changed. Real Liquid Glass materials; the palette values carry over into the Mapo Glass palette ([UX.md](UX.md) §9). |
| No title bar | `browser/mapoWindowCorners.ts`; `electron-browser/mapoWindowControls.contribution.ts`; `browser/media/mapo.css` L296-394; core `titlebarPart.ts`, `titlebarpart.css`, `layoutService.ts`, `actions.ts` | Traffic lights centered in a 42 px band. Rail actions sit in the top-left corner; "Show Explorer" appears top right while the explorer is hidden. Header icons fade in on hover. | `app/Mapo` `MainWindowController` and toolbar | R-NF-6 | v1-changed. Traffic lights sit in the rail; toolbar ids are `toolbar.*`. |
| Sliding side bars | core `layout.ts` `slideSideBar`, `paneCompositePart.ts`, `part.css`, `sidebarPart.ts`, `auxiliaryBarPart.ts`, `terminalEditor.ts` | Opens in 260 ms and closes in 200 ms; the contents keep their full width; terminals resize once at the end; no animation with reduced motion. | `app/Mapo` split view; `MapoTerminal` resizes when the animation settles | R-NF-5, R-NF-1 | v1-changed. See PA-37. |
| Empty states | core `editorGroupWatermark.ts`; `browser/mapo.contribution.ts` L88-90 | The empty editor and the empty rail list New Workspace, New Terminal Tab and New Claude Tab. | `MapoUI` empty pane and empty rail | R-NF-3 | v1-changed |
| Palette and shortcuts | keybindings in `browser/mapoActions.ts`; VS Code command palette | ⇧⌘N, ⌘T, ⇧⌘T, ⌃⌘↓ and ⌃⌘↑, ⇧⌘[ and ⇧⌘], ⌘P, ⇧⌘X, ⌃⌘1 to ⌃⌘9. | `app/Mapo` menus; `MapoUI` palette | R-KEY-1, R-KEY-2 | v1-changed. The keyboard map in [UX.md](UX.md) §8 applies; ⌘P becomes ⌘K; ⌃⌘1 to ⌃⌘9 come back with actions. |
| Startup | `browser/mapoStartup.ts`; `browser/mapoWorkspaceService.ts` L1073-1093 | Hides the panel, opens rail and explorer, closes VS Code's restored terminals, activates the saved workspace. | `app/Mapo` launch; `MapoClient` `state.snapshot` | R-PER-1, R-NF-1 | v1-changed |
| VS Code chrome defaults | `browser/mapo.contribution.ts` L111-133 | Hides the activity bar, status bar, AI features, walkthroughs and workspace trust. | none | none | dropped. Native has no VS Code chrome. |
| Adopting foreign terminals | `browser/mapoWorkspaceService.ts` L161-185 | Assigns terminals created by VS Code's own actions to the active workspace. | none | none | dropped. Only the daemon creates terminals. |

### 2.10 Build, packaging and dev loop

| Feature | VS Code build source | What it does | Native home | Requirements | Status |
|---|---|---|---|---|---|
| Dev launcher | `scripts/mapo.sh` | Starts the dev Electron build without a folder and strips Claude's session variables. | `just app`, `just dev` | R-ENG-5 | v1-changed |
| Packaged app and CLI entry | `product.json`; `resources/darwin/mapo.svg`; `resources/darwin/code.icns`; `build/*`; `src/mapo-cli.ts` | Bundle `dev.mapo.Mapo`, data in `~/.mapo`, a `mapo-app` shell command, and a CLI entry that installs the asar resolver first. | `app/project.yml`; bundle `dev.mapo.app`; `Resources/bin/mapo` | R-PER-4 (M5) | dropped. VS Code packaging. `resources/darwin/mapo.svg` can seed the native icon. |
| Terminal scroll probe | `scripts/terminal-scroll-probe.py` | `scrollback` prints 20,000 styled lines; `tui --sync --animate` repaints a fullscreen screen. Needs no AI CLI. | `drives/` fixture | R-ENG-2 | v1-changed. Reuse it in `m0-skeleton` for replay and scroll checks. |
| Socket hardening | core `extHostCLIServer.ts` | Propagates listen errors, chmods the socket to 0600, caps request bodies at 1 MiB, cancels waits when the request closes. | `crates/mapo` daemon; `mapo-instance` | R-NF-4 | v1-changed. Adds the peer uid check and the 0700 runtime dir. |

## 3. Native v1 features with no VS Code counterpart

- Tiling split panes per workspace, and no tab strips (R-LAY-1 to R-LAY-4).
- Changes inspector with a unified diff and size warning (R-GIT-1 to R-GIT-3); editor git gutter (R-ED-3).
- TextKit 2 editor with tree-sitter highlighting (R-ED-1 to R-ED-7).
- Sessions that survive quitting, crashing and rebuilding the app (R-TAB-6, R-PER-1 to R-PER-4).
- Server detection by listening port in ordinary tabs (R-SRV-1 to R-SRV-4).
- macOS notifications, dock badge, done cleared on view, ⌘J (R-ST-3 to R-ST-6).
- `done` and `failed` for long shell commands (R-TAB-11).
- The automation surface `mapo ui` and drives (R-ENG-1, R-ENG-2).
- Instances and parallel worktrees (R-ENG-3 to R-ENG-5).

## 4. Code map

### 4.1 Files under `src/vs/workbench/contrib/mapo/` (47 files, 7,281 lines)

| File | Lines | Role | Native counterpart |
|---|---|---|---|
| `browser/mapo.contribution.ts` | 170 | Registers services and views (rail in the side bar, Explorer in the auxiliary bar, Agent Activity in the panel), default settings, corner menus | `app/Mapo/` window wiring; `MapoUI` |
| `browser/mapoActions.ts` | 589 | UI actions with keybindings, menus and pickers: new tab and workspace, rename, delete, pin and move, agent command, interrupt, server start and stop, tab picker, actions, mprocs, ports | `app/Mapo/` menus; `MapoUI` palette and context menus. The logic stays in daemon commands. |
| `browser/mapoActivityView.ts` | 70 | Agent Activity list in the bottom panel | later; data through `activity.list` |
| `browser/mapoAgentSessions.ts` | 208 | Per-launch hook token, generated Claude settings, reporter, MCP config and skill folder; the hook status machine; title fallback | `mapo-agent`; `plugin/`; `mapo hook` in `crates/mapo` |
| `browser/mapoCommands.ts` | 623 | Every `mapo.*` command: validation, result shapes, read, wait, run, ask, process list and stop, mprocs open, server operations | `mapo-core` dispatch, with `mapo-term` for read, wait and run, `mapo-agent` for ask, `mapo-proc` for processes |
| `browser/mapoControlService.ts` | 221 | Tokens, allowlist, caller resolution, guards, activity log, event ring | `mapo-core` credentials, guards, activity and events; `mapo-instance` tokens |
| `browser/mapoEditorSessions.ts` | 160 | Captures and restores each workspace's editor layout; dirty-file confirmation on switch | `mapo-core` layouts and `file_panes`; `MapoUI` split tree; `MapoEditor` recovery |
| `browser/mapoExplorerActions.ts` | 26 | Refresh and Collapse title actions | `MapoUI` inspector header |
| `browser/mapoExplorerDataSource.ts` | 54 | Lists a folder, folders first, filters excluded names | `mapo-git` `fs.list` |
| `browser/mapoExplorerView.ts` | 379 | Tree that follows the focused terminal's cwd, path row, states, watchers, refresh and collapse, open beside the terminal | `MapoUI` inspector Files; `mapo-git` `fs.watch` |
| `browser/mapoGitBranch.ts` | 60 | Branch from `.git/HEAD`, walking up, following worktree `gitdir:` files; short sha when detached | `mapo-git` branch reader |
| `browser/mapoNameDialog.ts` | 167 | Centered naming card | `MapoUI` inline rename |
| `browser/mapoRepositories.ts` | 77 | Repository membership service | later |
| `browser/mapoRepositoryActions.ts` | 65 | Repository pickers | later |
| `browser/mapoScriptActions.ts` | 191 | `.mapo/actions` discovery, runs, pins, palette entries | later |
| `browser/mapoServerSessions.ts` | 253 | Managed server lifecycle over shell integration, logs, URL detection | later; v1 detection in `mapo-proc` |
| `browser/mapoSetupActions.ts` | 81 | Save and open setup dialogs | later |
| `browser/mapoSetups.ts` | 90 | Setup storage | later |
| `browser/mapoStartup.ts` | 66 | Startup layout, editor tab labels and hovers, per-group Stop context key, restore | `app/Mapo` launch; `MapoUI` pane headers |
| `browser/mapoStatus.ts` | 128 | State vocabulary, priority, workspace summary, hover text, Stop rule | `mapo-core::status`; `MapoUI` colors |
| `browser/mapoViews.ts` | 35 | View ids, context keys, menu ids, command ids | none; native controls use the accessibility identifier scheme in [ENGINEERING.md](ENGINEERING.md) §4 |
| `browser/mapoWindowCorners.ts` | 86 | Toolbars in the top window corners when there is no title bar | `app/Mapo` window and toolbar |
| `browser/mapoWorkspaceService.ts` | 1109 | Owns the state: workspaces, tabs, terminal lifecycle, switching, launch, status inputs, branches, restore, resume | `mapo-core` actor and state; `mapo-term` PTYs; `mapo-agent` |
| `browser/mapoWorkspacesView.ts` | 352 | Rail list: rows, marks, hover, row actions, keyed refresh, scroll and focus rules | `MapoUI` rail |
| `browser/media/mapo.css` | 394 | Rail, explorer, activity, name dialog, quiet header icons, window corners | `MapoUI` row views and theme |
| `browser/media/mapoGlass.css` | 69 | Backdrop, card shadows, frosted overlays | `MapoUI` theme with Liquid Glass |
| `common/mapoAgentReply.ts` | 28 | Cuts Claude's answer out of the screen for `tab ask` | dropped; Stop `last_assistant_message` replaces it |
| `common/mapoControl.ts` | 44 | Public command allowlist; request, event and activity types | `mapo-protocol` |
| `common/mapoMprocs.ts` | 11 | mprocs project type | later |
| `common/mapoProcesses.ts` | 28 | Listener, process and Claude-process types | `mapo-protocol` `proc.ports` result |
| `common/mapoRepositories.ts` | 24 | Repository list parser | later |
| `common/mapoSetups.ts` | 75 | Setup parser and whitelist | later |
| `common/mapoSkill.ts` | 52 | The agent skill text | `plugin/skills/mapo/SKILL.md`; frozen copy in `reference/vscode-build/SKILL.md` |
| `common/mapoWorkspace.ts` | 145 | Model types and tolerant JSON parsing of saved state | `mapo-core` state model and SQLite migrations |
| `electron-browser/mapoWindowControls.contribution.ts` | 60 | Centers the traffic lights in a 42 px band | `app/Mapo` window |
| `node/mapoCli.ts` | 167 | CLI parsing, help, dispatch, output, exit codes | `crates/mapo` |
| `node/mapoCliFormat.ts` | 79 | Tables and raw text for people | `crates/mapo` output module |
| `node/mapoCliTransport.ts` | 29 | One HTTP request per call over the window socket, found through a rendezvous file | `crates/mapo` client, NDJSON JSON-RPC |
| `node/mapoMcp.ts` | 109 | MCP server and tool definitions | `mapo-mcp` |
| `node/mapoMprocsConfig.ts` | 60 | mprocs YAML inspection | later |
| `node/mapoProcesses.ts` | 116 | Listeners through `lsof` and `ps`, identity, SIGTERM stop; Claude session discovery | `mapo-proc`; session ids move to `mapo-agent` |
| `test/browser/mapoExplorerDataSource.test.ts` | 51 | Sort and filter tests | `mapo-git` unit tests |
| `test/browser/mapoGitBranch.test.ts` | 50 | Branch reader tests: subfolder, worktree, detached, outside a repo | `mapo-git` unit tests; port the four cases |
| `test/browser/mapoStatus.test.ts` | 53 | Vocabulary and workspace summary tests | `mapo-core::status` unit tests; port the cases |
| `test/browser/mapoWorkspaceService.test.ts` | 287 | Service lifecycle tests with fake terminals | drives `m0-skeleton` and `m1-daily`, not unit tests (R-ENG-2) |
| `test/common/mapoAgentReply.test.ts` | 32 | Reply extraction test | dropped |
| `test/common/mapoWorkspace.test.ts` | 58 | Model parsing tests | `mapo-core` persistence tests where the logic is pure |

### 4.2 Core VS Code edits (25 files, +437/−83)

The upstream base is `75f204b2af6`. List them with `git -C ~/code/mapo-native diff --stat 75f204b2af6 a7bc6c9e73e -- src/vs ':!src/vs/workbench/contrib/mapo'`.

| File | +/− | Change | Native counterpart |
|---|---|---|---|
| `src/vs/base/common/labels.ts` | +6/−0 | `tildify` returns `~` for the home folder itself | display helper in `MapoUI` and `crates/mapo` |
| `src/vs/base/test/common/labels.test.ts` | +1/−0 | Test for the line above | none |
| `src/vs/platform/actions/common/actions.ts` | +1/−0 | `MenuId.TitleBarLeft` | none |
| `src/vs/sessions/browser/workbench.ts` | +3/−0 | `isSliding` stubs for the sessions workbench | none |
| `src/vs/workbench/api/node/extHostCLIServer.ts` | +50/−18 | Readiness errors, socket 0600, 1 MiB body cap, request types `mapo`, `mapoEvents`, `mapoHook`, cancel on close | daemon socket server in `crates/mapo`, dispatch in `mapo-core` |
| `src/vs/workbench/api/node/extHostExtensionService.ts` | +32/−2 | Always-on CLI server; internal commands `installCli` (writes the `mapo` launcher), `cliInfo`, `listListeners`, `stopListener`, `findAgentSessions`, `inspectMprocs`; `channelReady` after a host restart | bundled `mapo` on PATH; `mapo-proc`; `mapo-agent` |
| `src/vs/workbench/browser/layout.ts` | +110/−1 | Animated side bar slide | `app/Mapo` split view animation |
| `src/vs/workbench/browser/media/part.css` | +14/−0 | Slide offset and fade | none |
| `src/vs/workbench/browser/parts/auxiliarybar/auxiliaryBarPart.ts` | +1/−1 | Minimum width 0 while sliding | none |
| `src/vs/workbench/browser/parts/sidebar/sidebarPart.ts` | +1/−1 | Minimum width 0 while sliding | none |
| `src/vs/workbench/browser/parts/paneCompositePart.ts` | +25/−0 | Lays contents out at full width during a slide | none |
| `src/vs/workbench/browser/parts/editor/editorGroupWatermark.ts` | +10/−39 | Mapo entries in the empty-editor watermark | `MapoUI` empty pane |
| `src/vs/workbench/browser/parts/titlebar/titlebarPart.ts` | +12/−0 | `TitleBarLeft` toolbar after the window controls | `app/Mapo` toolbar |
| `src/vs/workbench/browser/parts/titlebar/media/titlebarpart.css` | +12/−0 | Styles for that toolbar | none |
| `src/vs/workbench/contrib/terminal/browser/terminal.ts` | +4/−0 | `programTitle` and `onDidChangeProgramTitle` API | `mapo-term` keeps the OSC 0/2 title apart from the display name |
| `src/vs/workbench/contrib/terminal/browser/terminalEditor.ts` | +13/−0 | Skips terminal reflow while a side bar slides | `MapoTerminal` resize when the animation settles |
| `src/vs/workbench/contrib/terminal/browser/terminalEditorInput.ts` | +29/−3 | Owner-set label and hover, glyph stripping, "Claude" for version titles, status icons | pane header in `MapoUI`; title rules in `mapo-core` |
| `src/vs/workbench/contrib/terminal/browser/terminalInstance.ts` | +54/−9 | Program title; command id armed after the Ctrl-C prompt cleanup; detached terminals marked invisible; provisional Process exit reason during exit listeners; reuse resets exit state; environment relaunch skipped once input arrived | lessons for `mapo-term`: PA-15 and §5.8 |
| `src/vs/workbench/contrib/terminal/browser/terminalService.ts` | +3/−3 | Awaits the editor before returning a new terminal | none |
| `src/vs/workbench/contrib/terminal/test/browser/terminalInstance.test.ts` | +33/−4 | Tests for the exit reason fix | none |
| `src/vs/workbench/services/layout/browser/layoutService.ts` | +13/−1 | `isSliding` API; no custom title bar on macOS when set to `never` | none |
| `src/vs/workbench/services/themes/common/workbenchThemeService.ts` | +1/−1 | Default dark theme is Mapo Glass | `config.toml` `[ui] theme = "mapo-glass"` |
| `src/vs/workbench/test/browser/workbenchTestServices.ts` | +2/−0 | Test stubs | none |
| `src/vs/workbench/workbench.common.main.ts` | +4/−0 | Imports the contribution | none |
| `src/vs/workbench/workbench.desktop.main.ts` | +3/−0 | Imports the window-controls contribution | none |

### 4.3 Other files on the branch

| File | Lines | Role | Native counterpart |
|---|---|---|---|
| `src/mapo-cli.ts` | 14 | Packaged CLI entry that installs the asar resolver, then loads `mapoCli.js` | `crates/mapo` |
| `scripts/mapo.sh` | 25 | Dev launcher; unsets `CLAUDE_CODE_*` and `CLAUDECODE` | `just app`, `just dev` |
| `scripts/terminal-scroll-probe.py` | 119 | Scrollback and fullscreen repaint probe | `drives/` fixture |
| `extensions/theme-defaults/themes/mapo-glass.json` | 171 | Mapo Glass color theme, plus 7 lines registering it | `MapoUI` palette |
| `product.json` | +22/−22 | Product rename: `dev.mapo.Mapo`, `~/.mapo`, `mapo:` URL scheme, `mapo-app` | `app/project.yml` |
| `resources/darwin/mapo.svg`, `code.icns` | 34 | App icon: rail, prompt and file tree | icon source for `Mapo.app` |
| `package.json`, `package-lock.json` | +2/−1 in `package.json` | Runtime dependencies `@modelcontextprotocol/sdk` and `js-yaml`; the lock file was regenerated | rmcp; no YAML in v1 |
| `build/gulpfile.vscode.ts`, `build/lib/esbuild.ts`, `build/next/index.ts`, `build/lib/i18n.resources.json` | +9/−3 | Packages without Copilot; bundles `mapo-cli`; localization entry | none |
| `docs/mapo/*.md`, `docs/mapo/evidence/*.json`, `docs/mapo/screenshots/**` | 1,426 in the markdown | Designs, delivery reports, handoff, evidence, 111 screenshots | four copied to `reference/vscode-build/`; the rest stays on the branch (§7) |
| `docs/superpowers/specs/*`, `docs/superpowers/plans/*` | 2,417 | Original workspace spec and plans | reference only |

## 5. Port notes

Each note gives the old source, the logic worth keeping, the native target, and what to watch for.

### 5.1 Hook-event status machine

Source: `browser/mapoAgentSessions.ts` L16-28 state, L98-114 hook registration, L117-152 `receive`, L154-157 `get`, L159-162 `interrupt`, L164-177 `submit`, L180-182 `turnStartedSince`, L186-188 `commandFinished`. Display mapping in `browser/mapoWorkspaceService.ts` L1038-1044 and `browser/mapoStatus.ts` L69-81.

Native target: `crates/mapo-agent`, as a plain struct with unit tests, fed by `hook.report` from `mapo hook`. `mapo-core::status` reads the derived state.

Per-tab agent state:

```text
AgentState {
  status: Idle | Running | Done          // the main agent
  attention: Set<Scope>                  // scopes waiting on the user
  subagents: Set<Scope>                  // running subagents
  interrupted: bool
  hooks_connected: bool                  // any accepted hook since launch
  turn_started_at: Option<Instant>       // last UserPromptSubmit
  optimistic: Option<{prior, sent_at}>   // see submit()
}
Scope = the hook's agent_id, or "" for the main agent
```

`receive(event, scope)` applies these steps in order:

1. If the event is UserPromptSubmit or SessionStart, set `interrupted = false`.
2. If `interrupted` and the event is PostToolBatch, Stop, Notification, PermissionRequest or SubagentStart, ignore it and return the current state. SubagentStop, StopFailure and SessionEnd still apply.
3. Apply the event:

| Event | Effect |
|---|---|
| UserPromptSubmit | `attention.clear()`; `status = Running`; `turn_started_at = now`; cancel the optimistic revert |
| PostToolBatch | `attention.remove(scope)`; if `scope == ""` then `status = Running` |
| SubagentStart | if `scope != ""` then `subagents.insert(scope)` |
| SubagentStop | `subagents.remove(scope)`; `attention.remove(scope)` |
| Notification, PermissionRequest, StopFailure | `attention.insert(scope)` |
| Stop | `attention.remove(scope)`; `status = Done` |
| SessionStart, SessionEnd | `attention.clear()`; `subagents.clear()`; `status = Idle` |
| any other event | reject with `invalid_argument` |

4. Set `hooks_connected = true` and emit the change.

Derived state: `needs-you` when `attention` is not empty, else `running` when `subagents` is not empty, else `status`.

`interrupt()` runs after Mapo writes ESC (`\x1b`): `interrupted = true`, clear `attention` and `subagents`, `status = Idle`.

`submit()` runs when `tab send` with execute targets an agent tab and the text does not start with `/` (`browser/mapoWorkspaceService.ts` L570). It sets `interrupted = false`, clears `attention`, saves `prior = status`, sets `status = Running`, and after 6 s restores `prior` if the status is still Running and no UserPromptSubmit arrived after the send.

Only Notification types `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` and `agent_needs_input` count. The old build filtered them with the hooks.json matcher (L106). Idle reminders and auth notifications must never create attention.

An agent tab with no hook yet shows `starting` ("Starting"), or `needs-you` while the trust or login screen matcher fires. A session without hooks uses the title fallback (`statusSource: title`).

Watch for:

- `hooks_connected` belongs to the tab and must survive `/clear` and `/resume`, which emit SessionEnd then SessionStart in the same process. The first VS Code draft revoked the hook credential on SessionEnd and lost every later hook (DELIVERY-1-REVIEW, finding 1).
- A Stop that arrives while subagents run keeps the tab `running` until the last SubagentStop.
- Stop does not fire on Esc. Step 2 is what keeps a late PostToolBatch or Stop from turning an interrupted tab back to Working or Done.
- StopFailure is not suppressed while interrupted. If drives show a false needs-you right after Esc, add it to the step 2 list.
- Hooks win over the title. Claude can keep a spinner glyph in its title after Stop: `docs/mapo/evidence/delivery-1.json` records state `done` with title `◑ MAPO_API_OK`.
- When the shell command that started Claude finishes, the old build dropped the agent state (L186-188). Native: on the OSC 133;D that ends the Claude command, reset the agent state and fall back to shell status.
- `mapo hook` must exit 0 within 2 s whatever happens. The old reporter capped stdin at 16 MiB, gave the request 2 s and hard-exited at 2.5 s (L81, L91-96).

### 5.2 Status vocabulary and priority

Source: `browser/mapoStatus.ts` L14-17, L56-84, L87-105, L123-128. Tests: `test/browser/mapoStatus.test.ts` L18-52.

Native target: `mapo-core::status`, one pure function from tab facts to `(state, stateLabel, stateDetail)`, plus the workspace fold. Port the test cases.

Tab rule, first match wins:

1. `launchError` set: `failed`, "Couldn't start"; the detail is the reason.
2. Native addition: a command that exited non-zero after running 30 s or more, or while serving: `failed`, "Failed", detail "exit N" (R-TAB-11, R-SRV-3).
3. Needs input (hook attention, trust screen, BEL if kept): `needs-you`, "Needs you".
4. Running: `running`, "Working" when the source is hooks or title, else "Running".
5. Done: `done`, "Done".
6. Exited: `stopped`, "Stopped".
7. Not started: `idle`, no word; spoken "Not started".
8. Hooks source but not connected: `starting`, "Starting".
9. Otherwise `idle`, no word; spoken "Idle".

Workspace fold, from `describeWorkspaceState`:

- Compute every tab's state and count each state.
- Skip steady tabs. The old build skipped a running server; native should skip a serving tab (PA-34).
- The headline is the lowest index in `[needs-you, failed, running, done, starting, stopping, idle, stopped]`.
- With no headline, or a headline without a word, or `stopped`: state `idle`, summary "".
- Summary: "N working" when the headline is `running` and more than one tab is working; otherwise the phrase for the headline tab: "{name} needs you", "{name} failed", "{name} couldn't start", "{name} is working", "{name} is running", "{name} is done", "{name} is starting", "{name} is stopping", "{name} stopped".

Stop control (`describeTabStop`): an agent tab in `running` gets Interrupt; managed servers got Stop or Start (later). Native also offers Stop (Ctrl-C) for a running shell command (R-LAY-6).

Watch for:

- The old build had a second, legacy priority list for its `status` field (`browser/mapoWorkspaceService.ts` L979). Do not port it; results carry `state` only. HANDOFF §11 lists the double field as an open problem.
- Old labels "Starting…" and "Stopping…" end with an ellipsis; R-ST-1 says "Starting" and "Stopping". Use R-ST-1.
- The spoken label always has a word ("Idle", "Not started") even when the rail shows none; VoiceOver and the CLI use it.
- Tones map to the status colors of the Mapo Glass palette ([UX.md](UX.md) §9): attention `#E8B557`, error `#F47067`, active `#6CA8FF`, success `#6FCF97`, muted `#9EA3AE`.
- `done` stayed until the next event in the old build; native clears it once viewed (R-ST-5).

### 5.3 `tab wait`: patterns only after the last send

Source: `browser/mapoWorkspaceService.ts` L567-593 `sendToTab` (marker L571-576, pending flag L577-580), L595-602 `lastSendOutputLine`; `browser/mapoCommands.ts` L323-378 `tab.wait`, L155-165 `bufferText`, L119-142 `read`.

Native target: `mapo-term` for grid text, markers and the output boundary; `mapo-core` for the waiter registry.

Old algorithm:

1. `tab send` with execute records a marker at the cursor's absolute row before writing, replacing the tab's previous marker. It also marks the tab pending, so it counts as running until shell integration reports the command.
2. `lastSendOutputLine` is the marker row plus one, then skips rows that continue a soft wrap, because the echoed command may wrap.
3. On a shell tab, `--until TEXT` compares against the logical lines from that row to the end of the buffer, rows below the cursor included. With no live marker it starts at the cursor's row when the wait began.
4. On an agent tab (hooks or title source) it compares against the last 10,000 logical lines, because TUIs redraw in place.
5. The match is a literal, case-sensitive substring. The check runs once at registration, after every parsed output write and after every state change.
6. `--until idle` resolves on `idle` or `done`. On a shell tab without shell integration it fails with "Waiting for shell idle requires shell integration".
7. Failures: timeout (default 30 s, maximum 3,600,000 ms) "Timed out waiting for tab"; "Tab closed while waiting"; client cancellation. Server tabs matched only the current run and failed as soon as the server failed.

Native approach:

- With shell integration, use the first OSC 133;C after the send as the start of output; it comes after the echoed command line. Keep the row-marker rule as the fallback when no 133;C arrives, for example raw input to a program.
- Store the boundary as an absolute line (history size plus row) so scrolling does not move it. If scrollback trimming removed it, start at the top of the kept buffer, never at "now".
- Include the current unterminated line (PA-12).
- Match against the emulator's parsed text, not raw PTY bytes; escape sequences split words. The old build checked after xterm's `onWriteParsed`.
- PROTOCOL's default timeout is 600,000 ms; the old default was 30,000 ms.

Watch for:

- Premature idle. Mark the tab busy at send time (PA-10); DELIVERY-0 measured `sleep 3` finishing in 3 ms before this fix.
- Old output. A pattern from an earlier run must not match (PA-13). DELIVERY-2 checked a stopped server whose old ready line was still on screen.
- Wrapped spaces. Joining wrapped rows must keep the space at the wrap point (PA-11).
- Agent tabs. The whole-buffer rule can match the prompt Mapo just pasted, which §8.6 forbids; see PA-14.

### 5.4 `tab read`: rows below the cursor, logical lines

Source: `browser/mapoCommands.ts` L119-142 `read`, L155-165 `bufferText`; OVERNIGHT checkpoint 9 with `docs/mapo/evidence/terminal-menu-read.json`; MPROCS-DELIVERY for the alternate screen.

Algorithm:

```text
lines = input.lines ?? 50        // PROTOCOL default: 200. Valid range 1..=10000
if normal buffer:
    end = buffer_len
    cursor_end = absolute_cursor_row + 1
    while end > cursor_end and row(end - 1) is blank: end -= 1    // drop trailing blank rows, never above the cursor row
else (alternate screen):
    end = buffer_len                                               // the whole viewport
start = end; logical = 0
while start > 0 and logical < lines:
    start -= 1
    if row(start) does not continue the previous row: logical += 1
text = rows start..end joined into logical lines: a continuation row is appended to the previous line,
       and a row is right-trimmed only when the next row does not continue it
```

Native target: `mapo-term`, reading the alacritty_terminal grid. `tab.read` returns `{tabId, text, altScreen, cursor}`.

Watch for:

- Wrap orientation. xterm.js flags the continuation row (`isWrapped`); alacritty_terminal sets `Flags::WRAPLINE` on the last cell of the row that continues onto the next. Convert once, in one helper, with a unit test.
- Claude draws its menus below the cursor in the normal buffer. The folder-trust dialog puts "Yes, I trust this folder" and the help footer there, and the first version of `read` cut them off.
- PROTOCOL drops trailing blank rows in both buffers; the old alternate-screen branch kept them. Dropping them is fine.
- The old error for a tab without a terminal was "Terminal output is not available; focus the tab to start it". Native tabs always have a PTY unless the launch failed; return `unavailable` naming the launch error.
- `--lines` counts logical lines, so a long wrapped shell line reads back as one line (PA-11).

### 5.5 `tab ask`: from screen scraping to `last_assistant_message`

Old flow, `browser/mapoCommands.ts` L412-461:

1. The target must be a started agent tab (hooks or title source); otherwise "not an agent tab; use tab run for shell commands".
2. Reject a target that is `running` or `starting` ("wait for it first").
3. Note `sentAt` and wait up to 3 s for a UserPromptSubmit after it.
4. Send the prompt: bracketed paste, a 100 ms pause, then Enter (`browser/mapoWorkspaceService.ts` L582-588).
5. With no confirmation after 3 s, press Enter once more and wait 5 s; then fail with "did not start a turn; check the tab".
6. Wait until the state leaves `running` and `starting`. Default 600,000 ms, maximum 3,600,000 ms. Timeout message: "Timed out after 10 min; 'x' is still working. Use tab read or tab interrupt."
7. Wait for 400 ms without output (at most 3 s), read 60 lines, and cut the reply with `common/mapoAgentReply.ts`: the last `⏺` block after the echoed prompt, skipping tool calls, ending at the input rule or the turn footer.
8. Return `{tabId, state, reply, screen}`. The CLI prints the reply, or the screen, and exits 5 when the state is `needs-you`.

Native flow (R-AG-5, ARCHITECTURE §3.5):

- Require `agent.hooksConnected`. A title-only session cannot deliver `last_assistant_message`, so return `unavailable` with a hint to use `tab send` and `tab wait`.
- If the target is `needs-you`, return `needs_you` without typing (PA-5). If it is `running` or `starting`, wait until it is `idle` or `done` instead of rejecting.
- Reject prompts that start with `/` (PA-4).
- Keep steps 3 to 5 exactly: the pacing and the single Enter retry (PA-3).
- Arm a one-shot capture of the next Stop's `last_assistant_message` for this tab. Hold it only until the ask completes.
- Finish when the derived state becomes `done`. If Stop arrived while subagents still ran, keep its message and finish at the last SubagentStop.
- `needs-you` during the turn returns `needs_you` (exit 5); the turn continues in the tab.
- Timeout returns `timeout` (exit 124) and never interrupts the agent.
- Result: `{reply, turnMs}`.

Watch for:

- Slash commands can open menus and never fire UserPromptSubmit or Stop (COMMANDS.md, delivery 1).
- A person can type into the tab during an ask. Unless a Stop can be matched to the ask's UserPromptSubmit `prompt_id`, the next Stop counts as the ask's reply. Check the Stop payload for a correlating field when implementing T3.3, and document the rule in the skill.
- Do not port `common/mapoAgentReply.ts`. Screen replies were cut to the visible screen (HANDOFF §11).
- The old default timeout was 600,000 ms; PROTOCOL's is 1,800,000 ms. The old result shape `{tabId, state, reply, screen}` becomes `{reply, turnMs}`.

### 5.6 Process identity and safe stop

Source: `node/mapoProcesses.ts` L14-64; `browser/mapoCommands.ts` L584-623; guard `browser/mapoControlService.ts` L136; PROCESS-CONTROLS-DESIGN.md and PROCESS-CONTROLS-DELIVERY.md on the branch.

Old rules:

- Listing ran `ps -ax -o pid=,ppid=,uid=,lstart=,comm=` and `lsof -nP -a -u <uid> -iTCP -sTCP:LISTEN -Fpn` with a 5 s timeout and `LC_ALL=C`. `lsof` exiting 1 with empty stderr means no listeners. Ports come from the `n…:PORT` lines. Only the current user's processes count, and `command` is the basename of `comm`, never arguments or environment.
- Identity: sha256 of the JSON array `[pid, uid, lstart, command]`.
- Protected: the ancestry chain of the extension host that ran the listing, which includes the Mapo app process, up to launchd.
- Owner: the first process in the listener's ancestry, starting with the listener itself, that is a tab's shell.
- Stop takes a PID above 1 and an identity. Agents must pass `force`. It lists again and requires the same PID and identity still listening ("Process changed or stopped listening; refresh mapo ports"). It refuses protected processes ("Cannot stop Mapo or its process ancestors"), sends SIGTERM to that one PID and returns `{pid, signalSent: true}`. The human path confirms first and validates again after the dialog closes.

Native target: `mapo-proc`.

- Use libproc and the `listeners` crate. `proc_pidinfo` gives the start time in microseconds and the executable path. The identity is a hex hash of PID, start time and executable path (ARCHITECTURE §3.6).
- Find the owner by the tab's tty first, then by ancestry to a tab's shell PID.
- Protect mapod, every connected app, their ancestors, and PIDs 0 and 1.
- Never signal a process group, never escalate to SIGKILL, never claim the process exited.

Watch for:

- A race remains between the second check and `kill`. It is documented and accepted.
- `lstart` has one-second resolution; the libproc start time does not. Keep changing fields such as ports out of the identity.
- Double-forked servers lose their ancestry. The tty match catches most; the rest list with no owner.
- The old build stopped a managed server through its owner and then checked that the listener was gone. Review found a false success when a background listener survived (PROCESS-CONTROLS-DELIVERY). Native has no managed owner, so `process stop` reports only `signalSent`.

### 5.7 Names and titles

Source: `common/mapoWorkspace.ts` L63-65, L76-78; `browser/mapoWorkspaceService.ts` L470-476, L497-503, L986-996, L1097-1109; `browser/mapoAgentSessions.ts` L199-208; `browser/mapoCommands.ts` L183-191, L261-263, L283-290; `browser/mapoActions.ts` L526; core `terminalEditorInput.ts` `getName`.

Rules:

- Workspace names are trimmed and non-empty and may repeat. The default is the first unused "Workspace N", counting from 1. An ambiguous selector fails with "Workspace name missing or ambiguous; use --workspace with its ID".
- Tab names are unique in their workspace and match `^[^\s/]+$`. Automatic names are `<kind>-<N>` with the first unused N. A name that matches the automatic pattern is not labeled.
- A tab is `labeled` when its name was chosen: created with a non-automatic name, or renamed. A labeled tab's title is its name.
- An unlabeled tab's title is the program title with the leading glyph removed (any of `✳✢✣✶✻✽·◐◓◑◒⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` and the spaces after it). A bare version title matching `^v?\d+(\.\d+)+$` becomes "Claude". An agent tab whose title is empty or `zsh` shows "Claude". Otherwise an empty title shows "zsh".
- Renaming from a title turns runs of whitespace and `/` into `-`.
- The raw program title stays available (old `sessionTitle`), even on labeled tabs, and still feeds the title fallback.

Native target: `mapo-core` for name, labeled and title; `mapo-term` for OSC 0/2; `mapo-agent` for the glyph list.

Watch for:

- Native automatic names are `terminal-N` and `agent-N`, and `kind` values are `shell` and `agent`. Decide whether the CLI accepts the old `terminal` and `claude` values as aliases (R-CTL-2 compatibility).
- zsh sets no title by default; the old build fell back to the process name. Native titles come from Mapo's zsh integration (OSC 2). Keep "zsh" as the last fallback.
- A `/rename` typed into Claude before its prompt was ready was lost (OVERNIGHT, natural titles follow-up). Wait for `idle` before sending.

### 5.8 Launch diagnostics and failed-start retention

Source: `browser/mapoWorkspaceService.ts` L687-747 `ensureInstance`, L749-766 `describeLaunchFailure`, L768-779 `waitForProcess`, L874-891 `onInstanceDisposed`, L505-529 `focusTab`, L223-227 `enqueue`, L1026 failed raw status; `browser/mapoStatus.ts` L57; `browser/mapoWorkspacesView.ts` L241; core `terminalInstance.ts`; OVERNIGHT checkpoints 8, 10 and 11.

Old rules:

- Launch command: the tab's own command, else for agent tabs the workspace agent command, else `claude`.
- Ownership is checked before and after the process is created. A tab closed, or a workspace deleted, during the launch cancels it and disposes the process.
- Any failure before the shell is ready (exit, dispose, 30 s timeout) keeps the tab, marks it failed and stores a message:
  - missing folder: "Could not start {title}. Folder not found: {cwd}. Restore the folder, then retry."
  - not a folder: "Could not start {title}. This path is not a folder: {cwd}"
  - anything else: "Could not start {title}. {error}"
- `tab focus`, from a click, Enter or the CLI, retries. All focus and retry work runs through one queue, so eight concurrent focus requests started exactly one process (checkpoint 10).
- Success clears the error. Only an explicit close deletes the definition.
- A shell that exited after a healthy start, for example after `exit`, removed the tab, because VS Code closes a terminal editor whose process ends. Only startup failures and server tabs were kept.

Native target: `mapo-core` for `launchError`, a per-tab launch generation and single-flight retry in the actor; `mapo-term` for the cwd check and the first-prompt wait; `MapoUI` for the "Couldn't start" row and retry.

Watch for:

- Validate the cwd in the core before spawning (ARCHITECTURE §3.4, step 1). Give `launchError.kind` values such as `cwd_missing`, `cwd_not_directory`, `spawn_failed`, `exited_before_prompt` and `prompt_timeout`.
- A late diagnostic from an older attempt must not overwrite a newer successful attempt (PA-17).
- A failed launch never collapses its pane, and a retry never opens another pane (PA-19).
- One tab's failure never blocks other launches (PA-18).
- Without shell integration there is no OSC 133;A. Define readiness for that case, for example "child still alive after 1 s", or the 30 s timeout marks every such tab failed.
- Decide what a shell exit after a healthy start does (PA-20).

### 5.9 CLI output formatting

Source: `node/mapoCliFormat.ts` L12-79; `node/mapoCli.ts` L49-167.

Rules:

- Human output only when stdout is a terminal and `--json` is absent; otherwise compact one-line JSON. On a terminal, a result with no human form prints as JSON indented by 2 spaces.
- Raw text: `tab read` with trailing whitespace trimmed, `tab run` output as is, `server logs`. `tab send` prints nothing. `tab ask` prints the reply (or the screen) and appends a blank line and `[needs you: answer in the tab]` when the state is needs-you.
- Tables separate columns with two spaces, pad every column but the last to its widest cell, and right-trim each line.
- Tab table: `NAME  KIND  STATUS  WHERE`. KIND is `server` for server tabs, else the kind. STATUS is `stateLabel (stateDetail)`, or just `stateLabel`. WHERE joins the URL, the branch and the `~` path with two spaces.
- Workspace list: an unlabeled marker column (`*` active, `^` pinned), then `WORKSPACE  TABS  STATUS`. STATUS is the summary, else `Idle`, else `No tabs`.
- One workspace prints `Name (active)`, a blank line, and its tab table. One tab prints its single-row table, plus a `Last failure:` block for a failed server.
- Empty lists print `No tabs. Create one with: mapo tab new --name NAME`, `No workspaces. Create one with: mapo workspace new NAME`, or `Nothing to show.`
- Errors go to stderr: `mapo: <message>` on a terminal without `--json`, otherwise `{"error":"<message>"}`; exit 1. A refused or missing socket prints "Cannot reach Mapo from this terminal: its window was closed or reloaded. Run mapo from a tab in an open Mapo window."
- Exit codes: `tab ask` exits 5 on needs-you; `tab run` exits with the command's code, or 0 when unknown.
- `--help`, `-h` or no arguments print help. `mapo skill` works without a token; everything else needs one.
- Parsing: unknown options fail; `--` ends options; integer flags (`--lines`, `--timeout-ms`, `--slot`, `--port`, `--index`) are validated; relative `--cwd` and paths resolve against the CLI's cwd; `tab send` joins the remaining words with spaces; `--no-execute` sends raw input; `--tab-id ID` addresses a tab by ID.

Native target: the output module of `crates/mapo`. Add exit 2 for usage errors and 124 for timeouts (R-CTL-3). Give piped errors the shape in PA-40. The "cannot reach" message should name the instance and socket path and say how to start the daemon. PROTOCOL §9 has no `--tab-id`, because `tab` accepts an ID; keep `--tab-id` as an alias for compatibility.

### 5.10 Capabilities, allowlist and guards

Source: `browser/mapoControlService.ts` L83-161 (with L163-168 activity and L170-215 events); `common/mapoControl.ts` L7-18; core `extHostCLIServer.ts` request types `mapo`, `mapoEvents`, `mapoHook`.

Old dispatch order:

1. Authenticate the token to a caller `{workspaceId, tabId, name}`. An unknown token fails with "Mapo control requires a live terminal capability from this window".
2. The command must be on the public allowlist. Internal commands (`mapo.internal.*`, `mapo.agent.event`) and UI-only commands never cross.
3. `args` must be a JSON object.
4. `tab.wait`, `tab.run` and `tab.ask` get a cancellation token. Closing the request cancels them; revoking a token cancels its pending requests.
5. `workspace` (name or ID) must match exactly one workspace. The default is the caller's workspace.
6. Tab resolution applies to `tab.*` except `create` and `list`, to `server.*` except a creating `start`, and to `status NAME`. It resolves `tabId` in any workspace, else `name` in the resolved workspace, else the caller's own tab. A miss lists the names: "No tab named 'x' in this workspace. Tabs: a, b. Use --workspace for another workspace."
7. Guards: `process.stop` needs `force`; `workspace.rename` needs a non-empty name; `setup.delete` needs `force`; `workspace.delete` needs `force`; `tab.close` on another tab needs `force`; closing your own tab gets `force` automatically.
8. Execute. Every mutating command, which is everything except the read-only list at L112, records activity: `succeeded`, or `failed` when it threw or returned `{deleted: false}`, `{closed: false}` or `{stopped: false}`.
9. Tokens are two UUIDs per tab, issued again on relaunch and revoked when the terminal goes away. Hook tokens are separate and reach only the hook receiver.

Native target: `mapo-core` (credential table, dispatch, guards, activity) and `mapo-instance` (32-byte base64url tokens); PROTOCOL §3 to §5.

Watch for:

- Keep "an omitted tab means the caller's own tab" (PA-39). PROTOCOL marks `tab` as required.
- Activity targets are `pid:<n>` for process stops and the created ID for creates. Never record prompt text, tokens or whole argument objects.
- The app credential keeps human confirmations. An agent must never get a dialog it cannot answer; it gets a `forbidden` error that names the missing `--force` (CLI-DESIGN.md).
- The old events came from diffing a JSON string of every tab on every change (HANDOFF §11). Emit native events where the state changes.
- Event cursors: a cursor must be inside the ring, and one older than the first retained event minus one is expired. Register the subscriber before reading the ring so nothing falls between replay and live events.

### 5.11 Smaller rules worth keeping

- Agent input pacing, `browser/mapoWorkspaceService.ts` L582-588: bracketed paste, a 100 ms pause, then `\r` as a separate write.
- Agent launch, L729-737: the typed command starts with a space, and the echoed launch line is cleared once the command runs.
- Trust dialog strings, L1053 and `terminal-menu-read.json`: "Enter to confirm" and "trust this folder". Claude 2.1.28x also prints "Quick safety check: Is this a project you created or one you trust?" with "❯ No, exit" and "Yes, I trust this folder" drawn below the cursor.
- Serialization, L223-227: one queue runs activation, creation, focus and retry, deletion, file open and setup open. Dialogs about dirty files happen inside the queued operation, so Cancel leaves no partial state. In the daemon, the core actor gives the same ordering; per-tab single flight covers retries.
- Rail refresh, `browser/mapoWorkspacesView.ts` L215-221 and L270-319: one render per frame at most. When the rows and the active tab are unchanged, re-render only rows whose signature changed and keep selection and focus. When the active item changes, reveal it. When rows disappear, keep the scroll offset. When the focused row disappears, focus the row now at its index.
- Explorer, `browser/mapoExplorerView.ts` L274-323: a generation counter per root; a 4 s watchdog that retries once; a watch on the parent folder to catch the root being recreated; a recursive watch that skips `node_modules` and `.git`; refresh keeps the tree mounted; a 300 ms throttle.
- File open, `browser/mapoWorkspaceService.ts` L531-553: stat; reject missing, folder, broken symlink and non-regular files; activate the target workspace, which can be cancelled; focus its active tab; open beside it; fail if no editor opened.
- Branch reader, `browser/mapoGitBranch.ts` L12-56: at most 64 parents; `.git` may be a folder or a `gitdir:` file with a relative or absolute path; `ref: refs/heads/X` gives X, anything else its first 7 characters.
- For managed servers later, `browser/mapoServerSessions.ts` and `browser/mapoActions.ts` L63-74: reject a trailing `&`; URLs must be http or https without credentials; `0.0.0.0` and `[::]` become `localhost`; suggest a command from package.json scripts `dev`, `start` or `serve` and the lockfile (`pnpm dev`, `bun run dev`, `yarn dev`, `npm run dev`, `npm start`).
- MCP, `node/mapoMcp.ts` L22-73: the tool descriptions are good source text; input schemas are strict; tools set `readOnlyHint` and `destructiveHint`; failures return `isError` with the message; stdin `end` or `close` shuts the server down.

## 6. Behavior-contract check

REQUIREMENTS §8 lists 13 contracts learned in the VS Code build. This section checks them against OVERNIGHT-PROGRESS.md, HANDOFF.md §11 and the delivery reports on the branch, then proposes what §8 misses. REQUIREMENTS.md is unchanged; the coordinator decides what to adopt.

### 6.1 Coverage of §8

| §8 item | Evidence in the VS Code build | What §8 leaves out |
|---|---|---|
| 1. Failed launch keeps its definition; retries serialized | OVERNIGHT checkpoints 8 and 10: two missing-folder reloads kept the tab; eight concurrent focus requests started one process | Stale diagnostics, bounded startup, pane stability, shell exit after a healthy start: PA-17 to PA-20 |
| 2. Dirty text survives switching; Cancel leaves no partial state | DELIVERY-0; OVERNIGHT checkpoints 4, 5 and 12 | Deleting a workspace with unsaved files: PA-24 |
| 3. File click focuses the editor; no focus stealing or rail scrolling | FEATURE-RESEARCH (reported twice); DELIVERY-0; OVERNIGHT checkpoint 4 | In-place row updates and pending controls: PA-25 |
| 4. Deleting a workspace keeps the scroll and focuses the next row | OVERNIGHT, workspace deletion scroll follow-up | Which workspace becomes active; reorder visibility; tab rows: PA-24, PA-26 |
| 5. `tab read` includes rows below the cursor | OVERNIGHT checkpoint 9 | Logical lines and wrapped spaces: PA-11 |
| 6. `tab wait` patterns match only output after the last send | HANDOFF §11; COMMANDS.md "One-shot commands and waiting" | The old build applied this to shell tabs only; premature idle; unterminated lines; fail fast; prompt cleanup: PA-10 to PA-15 |
| 7. Stop only for working agents; interrupt reaches the clicked pane | OVERNIGHT, conditional Stop follow-up; `evidence/stop-visibility.json` | Nothing |
| 8. A chosen name is label and address; unnamed tabs show native titles | OVERNIGHT, native terminal titles follow-up | Nothing; details in §5.7 |
| 9. Explorer states, superseded refreshes, last focused tab wins | OVERNIGHT checkpoint 7 | Root recreation, the 4 s stall retry, focus and expansion on refresh: PA-32 |
| 10. `file open` rejects folders, missing paths, broken links, unreadable files | OVERNIGHT checkpoint 12 | Concurrent workspace switches and valid symlinks: PA-33 |
| 11. No inherited `CLAUDE_CODE_*` markers | HANDOFF §7 bug 5; DELIVERY-0 launcher isolation check | Nothing |
| 12. Trust and login dialogs are needs-you, never answered | OVERNIGHT checkpoints 9 and 10; HANDOFF §11 | Nothing |
| 13. Events carry no terminal contents | CLI-DESIGN.md; DELIVERY-1-REVIEW | Nothing |

### 6.2 Proposed additions

Each line is a proposed requirement. PA numbers are local to this document.

| ID | Proposed requirement | Source | Related |
|---|---|---|---|
| PA-1 | `needs-you` clears only through the agent's own hook events or an interrupt; viewing or focusing the tab never clears it. | DELIVERY-1: "Focus does not clear a real permission request" | R-ST-5 |
| PA-2 | After Mapo sends a prompt, the tab shows Working at once and returns to its previous state if no UserPromptSubmit arrives within 6 s. | `browser/mapoAgentSessions.ts` L164-177 | R-AG-3 |
| PA-3 | Text for an agent tab goes out as one bracketed paste, then Enter as a separate write at least 100 ms later; `tab ask` presses Enter once more if UserPromptSubmit has not arrived after 3 s, and fails if no turn starts within 5 s after that. | `browser/mapoWorkspaceService.ts` L582-588; `browser/mapoCommands.ts` L434-444 | R-AG-5 |
| PA-4 | `tab ask` rejects prompts that start with `/`, because slash commands can open menus and never fire UserPromptSubmit or Stop; use `tab send` for them. | COMMANDS.md, agent commands; `browser/mapoWorkspaceService.ts` L570 | R-AG-5 |
| PA-5 | `tab ask` never types into a tab that is `needs-you`; it returns `needs_you` (exit 5) at once, because typed text would answer the pending dialog. | Edge case: `browser/mapoCommands.ts` L420-421 rejected only running and starting | R-AG-5 |
| PA-6 | Every SessionStart, including after `/clear` and `/resume`, replaces the tab's stored session id and records Claude's `cwd` and `transcript_path`; SessionEnd never revokes the tab's hook credential; resume runs in the recorded cwd and only when the transcript file exists. | DELIVERY-1-REVIEW finding 1; `node/mapoProcesses.ts` L77-116; `common/mapoWorkspace.ts` L34-40 | R-AG-6, R-AG-7 |
| PA-7 | When Claude exits on its own, Mapo forgets its session id, so only sessions alive when the daemon stopped or crashed are resumed. | `browser/mapoWorkspaceService.ts` L795-796 | R-AG-7 |
| PA-8 | SHOULD: a Claude session typed by hand in a shell tab also resumes after a daemon restart, with the launcher that started it, such as `claude-work`, or `CLAUDE_CONFIG_DIR=<dir> claude`. | `browser/mapoWorkspaceService.ts` L736-737, L950-962 | R-AG-7 |
| PA-9 | SHOULD: a BEL from a shell tab without hooks marks it `needs-you` until the tab is focused or its command finishes. | `browser/mapoWorkspaceService.ts` L813-819, L1027-1028 | R-ST-1, R-ST-4 |
| PA-10 | `tab send` with execute marks the tab busy immediately, so a following `tab wait --until idle` returns only after the sent command has started and finished. | DELIVERY-0: `sleep 3` waited 3 ms before the fix | R-CTL-9 |
| PA-11 | `tab read --lines N` and pattern waits work on logical lines, joining soft-wrapped rows and keeping the spaces at the wrap point, so a wrapped line reads and matches as one line. | OVERNIGHT checkpoint 9; DELIVERY-0 "Literal pattern waits preserve wrapped spaces" | §8.5, R-CTL-9 |
| PA-12 | Pattern waits also match the current unterminated line, such as a ready message printed without a newline. | DELIVERY-2 "Ready output without a newline: Detected" | R-CTL-9 |
| PA-13 | A pattern wait fails as soon as the tab turns `failed`, instead of running to its timeout, and never matches output of an earlier run. | DELIVERY-2; COMMANDS.md, server commands | R-CTL-9, R-SRV-3 |
| PA-14 | On agent tabs, pattern waits match the rendered screen, because TUIs redraw in place, and the prompt Mapo just sent never satisfies the wait. | `browser/mapoCommands.ts` L346-351 matched the whole buffer for agents | §8.6 |
| PA-15 | Before typing a command on a tab's behalf (`tab run`, agent launch), Mapo clears unfinished input on the prompt line, and it ties OSC 133 marks to the command only after that cleanup. | DELIVERY-2 "Unfinished input at a stopped server prompt"; core `terminalInstance.ts` `runCommand` | R-CTL-9 |
| PA-16 | Commands Mapo types on its own, such as the agent launch and `--resume`, stay out of the user's shell history, and their echo is cleared before the agent draws. | `browser/mapoWorkspaceService.ts` L729-737; HANDOFF §11 "no longer echo plumbing" | R-TAB-1, R-TAB-5 |
| PA-17 | A successful retry clears the previous `launchError` and exit information, and a diagnostic from an older launch attempt never overwrites a newer attempt's result. | OVERNIGHT checkpoints 8 and 10 | R-TAB-9 |
| PA-18 | A launch waits at most 30 s for the shell's first prompt; an exit before the prompt fails that launch at once, and one tab's failure never blocks other tabs' launches or retries. | OVERNIGHT checkpoint 5 "Setup startup blocked the queue"; `browser/mapoWorkspaceService.ts` L768-779 | R-TAB-9 |
| PA-19 | A tab whose launch fails keeps its pane and the split tree unchanged, and retrying reuses that pane instead of opening another. | OVERNIGHT checkpoints 10 and 11 | R-LAY-1, R-TAB-9 |
| PA-20 | A shell that exits with code 0 after its first prompt closes its tab, as terminals and the VS Code build do; a non-zero exit leaves the tab `stopped` with the code and a Restart action. | `browser/mapoWorkspaceService.ts` L874-891; PROTOCOL §8 EXIT frame | R-TAB-7, R-TAB-9 |
| PA-21 | Stopping the daemon hangs up every tab's session and waits briefly for exit, so no orphaned server keeps a port into the next start. | DELIVERY-2 "Background server reload: orphan process and port conflict" | R-PER-3 |
| PA-22 | Closing a workspace's last tab keeps the workspace, and the Files inspector switches to its no-terminal state instead of keeping the old folder. | DELIVERY-0 | R-WS-1, R-FS-5 |
| PA-23 | ⌘T or ⇧⌘T with no workspace creates the first free "Workspace N" and opens the tab there; New Workspace from the UI opens with one shell tab, while `workspace new` over CLI or MCP creates an empty workspace. | OVERNIGHT "create immediately" follow-up; `browser/mapoActions.ts` L85-87, L125-135 | R-WS-1, R-TAB-2 |
| PA-24 | Deleting the active workspace activates the workspace below it, or the one above when it was last; deleting a workspace or closing a file pane with unsaved text asks Save, Don't Save or Cancel, and Cancel changes nothing. | `browser/mapoWorkspaceService.ts` L318-354; DELIVERY-0 | §8.2, §8.4, R-ED-5 |
| PA-25 | Rail and inspector lists update changed rows in place by stable ID, so background updates never reset focus, selection, expansion or hover, and a control whose action is running shows a pending state and ignores repeated clicks. | OVERNIGHT checkpoint 1; `browser/mapoWorkspacesView.ts` L281-293 | §8.3 |
| PA-26 | After a reorder by drag or `move`, the moved row keeps focus and is scrolled into view; removing a workspace or tab row focuses the next row without scrolling. | OVERNIGHT checkpoints 3 and 4 | §8.4 |
| PA-27 | Expected failures from UI actions, such as a missing folder, a failed launch or a file that cannot open, show as a non-blocking message with a recovery action, never as a modal error dialog. | OVERNIGHT checkpoints 6, 10 and 12 | R-NF-3 |
| PA-28 | Text inputs validate while typing and before advancing, prefilled paths are fully selected so typing replaces them, and cancelling at any step creates nothing. | OVERNIGHT checkpoint 2; HANDOFF §7 bug 3; DELIVERY-0 | R-TAB-2 |
| PA-29 | App shortcuts (⌘K, ⇧⌘N, ⌘T, ⌘J and the rest) work whichever pane has focus, including terminal surfaces and image or PDF previews. | OVERNIGHT checkpoint 7; DELIVERY-0 "Workspace shortcuts win their terminal conflicts" | R-KEY-2 |
| PA-30 | The rail supports type-to-select on workspace names and tab titles, and Enter activates the selected row. | OVERNIGHT checkpoint 13 | R-KEY-1 |
| PA-31 | A tab's branch refreshes when a command finishes, when the tab gains focus, and when `.git/HEAD` changes. | DELIVERY-0; IMPLEMENTATION-ORDER delivery 0 | R-WS-5, R-FS-2 |
| PA-32 | The Files tree recovers by itself when its root folder is deleted and recreated, keeps expansion and keyboard focus across refreshes, retries a listing that has not finished after 4 s, and says in its empty state when exclude rules hide files. | OVERNIGHT checkpoint 7; HANDOFF §11 | R-FS-3, R-FS-5, §8.9 |
| PA-33 | `file open` resolves its target workspace when the request arrives, so a concurrent workspace switch never lands the file elsewhere, and symlinks to regular files open normally. | OVERNIGHT checkpoint 12 | §8.10, R-LAY-5 |
| PA-34 | A serving tab counts as steady state, so it shows the serving dot and never becomes its workspace's headline state or summary. | `browser/mapoStatus.ts` L93-94; COMMANDS.md "Status vocabulary" | R-WS-7, R-SRV-1 |
| PA-35 | Every confirmation is an in-window sheet with `dialog`, `dialog.confirm` and `dialog.cancel` identifiers that `mapo ui` can answer; Mapo never shows a system-modal panel a drive cannot see. | OVERNIGHT checkpoint 4 (a native save dialog blocked the driver) and checkpoint 6 | R-ENG-1 |
| PA-36 | `ui.click`, `ui.press` and `ui.wait` resolve targets by model identity and scroll virtualized rows in the rail and Files tree into view first. | OVERNIGHT checkpoint 4: offscreen list rows could not be clicked | R-ENG-1 |
| PA-37 | Showing or hiding the rail or inspector never resizes terminals on every animation frame; each visible terminal resizes once when the animation settles. | core `layout.ts` and `terminalEditor.ts` at `a7bc6c9e73e` | R-NF-1, R-TAB-10 |
| PA-38 | Title changes that differ only in Claude's spinner glyph produce no event and no redraw; the daemon strips the glyph and emits `tab.updated` only when the visible title or the state changes. | `browser/mapoWorkspacesView.ts` L217-220; `browser/mapoAgentSessions.ts` L206-208 | R-NF-1 |
| PA-39 | With a `tab` credential, an omitted tab selector means the caller's own tab, and a name that does not resolve returns `not_found` listing the workspace's tab names. | `browser/mapoControlService.ts` L124-131; `node/mapoCli.ts` L14 | R-CTL-2, R-CTL-4 |
| PA-40 | Piped or `--json` CLI errors print one JSON line on stderr, `{"error": message, "kind": kind, "hint": hint}`, keeping the VS Code build's `error` field. | `node/mapoCli.ts` L162-167 | R-CTL-3 |
| PA-41 | `mapo mcp` requires `MAPO_TOKEN` and exits 1 with a clear message without it; closing its stdin cancels outstanding waits and exits 0. | MCP-DELIVERY.md | R-CTL-7 |
| PA-42 | `mapo activity` on a terminal prints one readable line per entry, such as "be-agent closed tab api, rejected: needs --force", while JSON keeps the raw fields. | HANDOFF §11 open item | R-CTL-6 |
| PA-43 | If `state.db` cannot be read or migrated, the daemon refuses to start with an actionable error and leaves the file untouched; a bad `config.toml` keeps the last good settings and reports the error. | OVERNIGHT checkpoint 5 "fails visibly and is preserved instead of overwritten" | R-NF-3, R-PER-2 |

### 6.3 Drive lessons from the overnight run

These are not product requirements. They belong in drive scripts and [ENGINEERING.md](ENGINEERING.md).

- Prove that a command ran with a marker computed at run time, such as `printf 'OK_%s\n' $((6*7))`, so the echoed command line cannot satisfy the check (checkpoints 6 and 8).
- Claude Code's auto-mode reviewer refused scripts that create agents ("Create Unsafe Agents") and a narrower one ("Auto-Mode Bypass"). Real-Claude drives use harmless prompts and drive Mapo through the CLI directly. Never route around a refusal (checkpoints 9 and 10).
- Claude asks for folder trust in every folder it has not seen. Drives either expect `needs-you` there or use a fixture folder that is already trusted.
- Subscribe to events before making the change you wait for (checkpoint 3).
- Screenshots can catch a transition frame. Wait for the state to settle before capturing (checkpoint 2).
- Record only what was reproduced. The overnight log marks checks as "not claimed as verification" when the probe did not exercise the real path; drives should do the same in `summary.md`.
- Touch only the drive's own instance and processes, and record their PIDs.

## 7. How to read old code

`~/code/mapo` is the frozen checkout and the user's daily driver. Do not edit, build, check out or run anything there. Read the code through git from this worktree, which shares the repository, or with `rg` on the files. Use the literal commit rather than a shell variable; zsh treats `$REF:s…` as a substitution modifier.

```sh
# One file, or a line range of it, at the frozen commit
git -C ~/code/mapo-native show a7bc6c9e73e:src/vs/workbench/contrib/mapo/browser/mapoAgentSessions.ts | sed -n '117,152p'

# Every file of the contribution
git -C ~/code/mapo-native ls-tree -r --name-only a7bc6c9e73e -- src/vs/workbench/contrib/mapo

# Search the frozen tree
git -C ~/code/mapo-native grep -n 'PostToolBatch' a7bc6c9e73e -- src/vs/workbench/contrib/mapo
rg -n 'launchErrors|describeLaunchFailure' ~/code/mapo/src/vs/workbench/contrib/mapo
rg -n "command\('mapo\.tab\." ~/code/mapo/src/vs/workbench/contrib/mapo/browser/mapoCommands.ts

# Core VS Code edits (75f204b2af6 is the upstream base)
git -C ~/code/mapo-native diff --stat 75f204b2af6 a7bc6c9e73e -- src/vs ':!src/vs/workbench/contrib/mapo'
git -C ~/code/mapo-native diff 75f204b2af6 a7bc6c9e73e -- src/vs/workbench/contrib/terminal/browser/terminalInstance.ts

# Why a line exists: history and blame (the repo config names an ignore-revs file this worktree lacks)
git -C ~/code/mapo-native log --oneline 75f204b2af6..a7bc6c9e73e -- src/vs/workbench/contrib/mapo/browser/mapoCommands.ts
git -C ~/code/mapo-native blame --no-ignore-revs-file -L 117,152 a7bc6c9e73e -- src/vs/workbench/contrib/mapo/browser/mapoAgentSessions.ts

# Old docs and evidence that were not copied into reference/vscode-build/
git -C ~/code/mapo-native show a7bc6c9e73e:docs/mapo/HANDOFF.md
git -C ~/code/mapo-native show a7bc6c9e73e:docs/mapo/DELIVERY-1-REVIEW.md
git -C ~/code/mapo-native show a7bc6c9e73e:docs/mapo/evidence/terminal-menu-read.json | jq .

# Screenshots: view them in place
open ~/code/mapo/docs/mapo/screenshots/overnight/31-claude-readable-menu.png
```

Useful search terms: `enqueue(` for serialized operations, `launchErrors` for failed starts, `sendMarkers` for the send marker, `awaitsAgentSetup` for the trust dialog, `mapoPublicCommands` for the allowlist, `describeTabState` for the vocabulary, `agentStatusFromTitle` for the title fallback, `findMapoAgentSessions` for resume.
