# Mapo command API

Workbench commands are the shared boundary for UI, CLI and MCP. Arguments and results are JSON. IDs are stable UUIDs. Names are unique within their workspace; pass `workspaceId` when resolving a name outside the active workspace. Failures reject with an actionable error, which transports must expose with a nonzero exit code.

Delivery 0 implements workspace list/create/rename/delete/activate, tab list/create/send/read/wait/focus/close, status, file open and notify. `mapo.workspace.new`, `mapo.tab.newTerminal` and similar command-palette actions collect input, then call these commands.

- `mapo.workspace.list {}` → array of workspace summaries
- `mapo.workspace.create {name?}` → created workspace summary
- `mapo.workspace.rename {workspaceId,name}` → updated summary
- `mapo.workspace.activate {workspaceId}` → active summary; rejects if cancelled
- `mapo.workspace.delete {workspaceId,force?}` → `{deleted}`; confirmation without `force`
- `mapo.tab.list {workspaceId?}` → array of tab summaries
- `mapo.tab.create {workspaceId?,name?,kind?:terminal|claude,cwd,command?,role?}` → tab summary
- `mapo.tab.send {workspaceId?,tabId?|name,text,execute?:boolean}` → `{sent}`; execute defaults false so raw input is not silently submitted
- `mapo.tab.read {workspaceId?,tabId?|name,lines?:number}` → `{tabId,text}`
- `mapo.tab.wait {workspaceId?,tabId?|name,until:idle|{pattern:string},timeoutMs?:number}` → tab summary; output pattern is literal text; idle requires shell integration and waits for the next ready prompt
- `mapo.tab.focus {workspaceId?,tabId?|name}` → tab summary
- `mapo.tab.close {workspaceId?,tabId?|name,force?}` → `{closed}`; cross-workspace closure confirms unless forced
- `mapo.status {workspaceId?,tabId?|name}` → tab or workspace status
- `mapo.file.open {path,workspaceId?:string,besideTerminal?:boolean}` → `{path}`. Opens an existing regular file (including a valid symbolic link). Missing paths, folders, broken links and editor failures reject; it does not create files. Validation precedes workspace activation, and cancelling a switch aborts the open.
- `mapo.notify {message}` → `{shown}`

MAPO_WORKSPACE_ID, MAPO_TAB_ID and MAPO_TAB_NAME are injected into created terminals. Transport authentication, streamed events and activity-log persistence are added with the CLI immediately after delivery 1. API arguments never confer caller identity: the transport supplies the verified caller. Server kinds and controls land in delivery 2.

## Agent commands (delivery 1)

- `mapo.workspace.configure {workspaceId?,agentCommand}` → updated workspace; applies to future launches. A tab's explicit `command` overrides the workspace default.
- `mapo.tab.interrupt {workspaceId?,tabId?|name}` → updated tab; sends Escape to Claude.
- `mapo.tab.next {}` / `mapo.tab.previous {}` → focused tab in the active workspace.
- `mapo.tab.pick` and `mapo.workspace.chooseAgentCommand` collect UI input and call the shared commands.

Tab results include `launchCommand`, `statusSource` (`hooks`, `title`, or `shell`), `hooksConnected`, and `sessionTitle` when available. Workspace results add `attentionCount` and `statusTabName`. Managed statuses include `done`; `wait until: idle` accepts `idle` or `done`. Shell waits still require shell integration. `send` acknowledges input delivery, not turn completion; wait separately before sending a dependent prompt. UI slash commands may open interactive menus rather than produce a turn-completion hook.

`mapo.agent.event` and `mapo.internal.cliInfo` are internal integration commands, not general agent entry points. The hook receiver requires a fresh per-launch capability, and only updates its authenticated tab. Caller-authenticated general CLI operations land next.

## Agent CLI

`mapo` is injected into Mapo terminal PATH. It uses the bundled runtime and a window-local socket; no external Node installation is needed.

```sh
mapo workspace new Obsess --json
mapo tab new --workspace Obsess --name be-agent --kind claude --cwd ../backend --json
mapo tab new --workspace Obsess --name frontend --cwd ../frontend --cmd "pnpm dev" --role server --json
mapo tab send be-agent "API contract changed; see docs/contract.md" --workspace Obsess --json
mapo tab send --tab-id TAB_ID "hello" --json
mapo tab wait frontend --workspace Obsess --until "ready on" --json
mapo tab read frontend --workspace Obsess --lines 50 --json
mapo events --follow
mapo activity --json
```

Names resolve in the caller's workspace, regardless of UI focus. Use `--workspace NAME_OR_ID` to select another workspace. Duplicate workspace names require an ID. Relative paths resolve against the CLI process cwd. `tab send` submits by default; `--no-execute` sends raw input. `tab wait --until idle` accepts idle or completed agents; other values match literal output. `--timeout-ms` bounds the wait.

Use `--force` to delete a workspace or close another tab. Self-close is authorized by the caller's capability. The activity view records changes and rejected destructive requests. JSON errors go to stderr with nonzero status. `mapo --help` lists the current verbs.

The public registry also includes `mapo.activity.list`. Internal socket commands are not public API. Hooks and CLI use separate capabilities. Events contain metadata rather than terminal contents; `--after ID` replays retained events and rejects expired cursors. A fresh window starts a new event sequence.

## Server commands (delivery 2)

A server is a terminal with `role: server`, a saved foreground `command`, `cwd`, optional HTTP(S) `url`, and `autoStart` defaulting to false. Shell integration must be available. Commands accept the usual `workspaceId` and `tabId` or `name` selectors.

- `mapo.server.start {name,command?,cwd?,url?,autoStart?}` creates a server when a command is supplied and the name is unused, or starts an existing definition. Supplying a new command for an existing name is rejected.
- `mapo.server.stop`, `.restart`, `.status`, `.openUrl` take the tab selector and return its summary, or the opened URL result.
- `mapo.server.logs {tabId?|name,lines?}` returns `{tabId,text}` with bounded logs across restarts.
- `mapo.tab.create` accepts `role: server`, `command`, `autoStart?` and `url?` as an equivalent creation path.

```sh
mapo server start backend --cwd ../backend --cmd 'pnpm dev' --json
mapo tab wait backend --until 'ready on' --json
mapo server restart backend --json
mapo server logs backend --lines 50 --json
mapo server open backend --json
mapo server stop backend --json
```

`server.state` is starting, running, stopping, stopped or failed. Running means shell execution was confirmed. Readiness waits match output from the current run and reject on failure. Restart waits for the existing foreground job to stop; a timeout never starts a duplicate. Last failure persists, while full logs remain in memory. Use `--auto-start` only when the definition should launch when its workspace is restored; otherwise relaunch restores a stopped server.

Workspace `status` is aggregated. `statusTab` identifies the tab responsible for that status and contains its details; `statusTabName` is the short label. Other top-level tab details, including cwd, branch and server URL, belong to the active tab. Use the nested tab summaries for per-tab state.

## MCP and bundled skill

`mapo mcp` serves stdio MCP tools named `mapo_workspace_list`, `mapo_tab_create`, `mapo_server_restart`, and so on. These are typed adapters to the same authenticated commands, with the same caller-relative targeting, destructive guards and activity log. Inputs reject unknown properties. Tool failures set `isError`; successful results include JSON text and `structuredContent.result`.

`mapo_events_wait {cursor?}` waits for state changes and returns the next cursor. Cancellation and closing stdin release pending socket requests. `mapo://skill` is a readable Markdown resource; `mapo skill` prints the same text.

Managed Claude tabs receive a session-local `--mcp-config` and an `--add-dir` containing the Mapo skill. This does not replace other MCP settings or write configuration to the repository. Capabilities stay in the terminal environment. Existing Claude sessions need a new launch to acquire the integration.

## Reusable actions

Scripts in the nearest repo's `.mapo/actions/` and `~/.mapo/actions/` appear in the command palette. Supported suffixes are `.sh`, `.zsh`, `.py`, `.js`, `.mjs`, and `.cjs`. Discovery never executes files. Shell actions use interactive zsh; Python and Node actions use `python3` and `node` from the terminal environment.

- `mapo.action.list {workspaceId?,cwd?}` returns action metadata and workspace pins.
- `mapo.action.run {workspaceId?,cwd?,name}` creates a terminal, runs once, and returns its `tabId`. Wait separately for completion.
- `mapo.action.pin {workspaceId?,cwd?,name,slot}` assigns slot 1–9.
- `mapo.action.unpin {workspaceId?,slot}` removes a pin.
- `mapo.action.runPinned {workspaceId?,cwd?,slot}` invokes it. Repo pins retain their repo; global pins use the invocation cwd.

Use explicit `repo:filename` or `global:filename` when the short name is ambiguous. Repo actions run from the repo root; global actions run from the caller's folder. CLI: `mapo actions --json`, `mapo run repo:check.zsh --json`, and `mapo action pin repo:check.zsh --slot 1 --json`. MCP exposes the corresponding typed `mapo_action_*` tools. Cmd+Ctrl+1 through 9 invoke pins on macOS. Pin state survives reload; executed scripts do not replay when their terminals restore.

## Existing mprocs projects

`mapo.mprocs.inspect {path}` reads YAML and returns the canonical path, working directory, process names, autostart/autorestart flags, and `control: terminal`. It never returns environment values. `mapo.mprocs.open {workspaceId?,path,name?}` opens or focuses the single owner tab for that config within this window; repeated and concurrent requests reuse it, including from another workspace. CLI: `mapo mprocs inspect mprocs.yaml --json` and `mapo mprocs open mprocs.yaml --json`. MCP uses `mapo_mprocs_inspect` and `mapo_mprocs_open`. The palette provides Open mprocs Project.

Existing string, argv, mapping and OS-selected process definitions are supported. Ambiguous numeric-key selector maps are rejected. mprocs continues to interpret all process settings. Mapo rejects configs requesting its unauthenticated TCP control listener. Per-process controls/status/logs remain in the mprocs TUI; use tab focus/read/send to interact. Full-screen reads include the viewport. Reload retains the config and tab identity but stops the session; open again to start it manually. This adapter does not discover mprocs instances outside this Mapo window or generate configs.

## Ports and processes

`mapo.process.list {port?}` returns current-user TCP listeners with PID, executable name, start time, identity, ports, protection state and owning Mapo tab when found. It excludes command-line arguments and environment values. `mapo.process.stop {pid,identity,force?}` requires a fresh identity from that list. CLI uses `mapo ports --port 3000 --json` and `mapo process stop PID --identity ID --force --json`; MCP tools are `mapo_process_list` and `mapo_process_stop`.

Agent transports require force. The palette's Show Ports and Processes picker offers focus and stop, with human confirmation. The stop path revalidates identity, rejects the app and its ancestors, and routes managed servers through `mapo.server.stop`. That result reports `ownerStopped: true, listening: false` only after checking the target listener disappeared; a surviving listener is an error. mprocs children are rejected so controls stay with their supervisor. Other processes receive SIGTERM to their single PID and return `signalSent: true`; this does not promise process exit. Refresh the list to observe listener state. macOS and Linux require lsof; Windows is unavailable. Revalidation reduces PID-reuse risk but is not an atomic process-handle guarantee.

## Workspace rail organization

`mapo.workspace.pin {workspaceId?,pinned:boolean}` pins or unpins a workspace. It moves to the end of the destination group; repeating the same value leaves order unchanged. `mapo.workspace.move {workspaceId?,index:number}` moves within its pinned or unpinned group using a zero-based index. Invalid indices fail without mutation. Both return the workspace summary; list and status include `pinned` and `position`. Pins and order survive reload and preserve active workspace and terminal ownership.

CLI: `mapo workspace pin NAME --json`, `mapo workspace unpin NAME --json`, and `mapo workspace move NAME --index 0 --json`. MCP: `mapo_workspace_pin` and `mapo_workspace_move`. Context-menu and palette actions call these same commands. Each changed organization publishes `workspace.organized`; agent mutations appear in Activity. Tab organization is described below; saved setups are described below.

## Tab rail organization

`mapo.tab.pin {workspaceId?,tabId?|name,pinned:boolean}` and `mapo.tab.move {workspaceId?,tabId?|name,index:number}` organize tabs using the same pinned/unpinned group rules as workspaces. Results, list and status include `pinned` and zero-based `position` within that group. CLI: `mapo tab pin NAME`, `mapo tab unpin NAME`, `mapo tab move NAME --index 0`; MCP: `mapo_tab_pin` and `mapo_tab_move`. Changed organization emits `tab.organized` and agent changes appear in Activity.

The active workspace expands into compact tab rows showing stable names, type, pin state and status. Click or Enter focuses the existing terminal. Context/palette actions pin or move tabs using shared commands. Saved order also controls next/previous-tab navigation; editor headers retain their independent split layout. Tabs keep their IDs, ownership, commands and processes. Inactive workspaces show their summary rows; activate one to see its tabs. Drag reordering remains pending.

## Saved setups

Save a reusable launch definition with `mapo.setup.save {workspaceId?,name,overwrite?}`. Names are unique; replacing one requires `overwrite: true` and preserves its setup ID. `mapo.setup.list {}` returns snapshots. `mapo.setup.open {setupId?|name,workspaceName?}` creates and activates a workspace with fresh tab IDs. It returns `{setupId,workspaceId,activated,failedTabIds}` after launch dispatch; wait separately for application readiness. `mapo.setup.delete {setupId?|name,force:true}` deletes only the saved snapshot.

CLI: `mapo setup save "Full stack" --workspace PROJECT --json`, `mapo setup open "Full stack" --workspace-name "Project copy" --json`, `mapo setup list --json`, and `mapo setup delete "Full stack" --force --json`. Use `--overwrite` to replace and `--setup-id` to address an ID. MCP exposes typed `mapo_setup_list`, `mapo_setup_save`, `mapo_setup_open` and `mapo_setup_delete`. Palette actions provide Save Workspace as Setup, Open Saved Setup and Delete Saved Setup; workspace context menus include Save. Agent operations are logged and publish `setup.saved`, `setup.opened` and `setup.deleted` with a setup ID.

Snapshots retain tab names, kinds, individual folders, order/pins, configured launch commands, workspace agent command, selected tab and server auto-start policies. They exclude terminal history/output, environment/capabilities, editor buffers, titles and failure state. Action tabs reopen as idle shells; their scripts never replay. Manual servers remain stopped; automatic servers and configured agent/shell commands launch in fresh sessions. This is not conversation resume. Deleting the source workspace does not delete its saved setup. mprocs tabs are rejected until supervisor ownership can be preserved safely.

Opening validates all folders before creating anything. Canceling a dirty-file switch leaves no extra workspace. Failed launches retain retryable definitions and report their tab IDs; successful peers remain running. Invalid or unsupported saved storage fails visibly and is preserved instead of overwritten. Optional repo membership is described below; drag reordering remains separate work.

## Optional workspace repositories

`mapo.repo.add {workspaceId?,path,name?}` remembers a named Git working-tree root. It accepts subfolders, resolves the nearest readable Git root, and supports linked worktrees. Names contain no whitespace or slashes; the default comes from the folder name with a numeric suffix if needed. Re-adding the same root is idempotent. Conflicting names fail without mutation. `mapo.repo.list {workspaceId?}` returns `{name,path,available,branch?}` entries; missing roots remain listed as unavailable. `mapo.repo.remove {workspaceId?,name}` removes membership metadata only, leaving tabs, processes and files alone.

CLI: `mapo repo add ../backend --name be --json`, `mapo repo list --json`, `mapo repo remove be --json`. Add `--workspace NAME_OR_ID` to target another workspace. MCP has matching typed `mapo_repo_*` tools. `mapo.tab.create {repo:"be",name:"be-agent",kind:"claude"}` and `mapo tab new --repo be --name be-agent --kind claude` resolve the stored root instead of cwd. Supplying both repo and cwd is an error. The selected repository must still be available at command execution. Ordinary cwd-based tabs remain independent of membership.

Palette and workspace context actions add/remove repositories and open Terminal or Claude tabs from a repo picker. The picker shows branches and unavailable paths. The focused terminal still drives the explorer. Membership changes publish `workspace.repositoriesChanged` and appear in agent Activity. Workspace summaries and saved setups include the ordered membership list; old definitions default to none. Setup opening validates every saved repo folder before creating a workspace, even when it has no tab there.

Membership does not clone, switch branches, create worktrees or change VS Code's underlying workspace folders. Symlink aliases are not collapsed to physical paths. Distinct working-tree roots stay distinct even when their Git storage is shared.

Tab results distinguish stable `name` (CLI/MCP addressing) from live `title` (what the rail and editor tab show). A name somebody chose (`tab new --name`, `tab rename`, server names) is `labeled` and is also the title. Unnamed tabs (`terminal-1`, `claude-1`) show the native title: `zsh`, then the shell/process title; Claude tabs show "Claude" until Claude sets a session title. Claude's own title stays available as `sessionTitle` on named tabs too.

## Status vocabulary

Every surface (rail, editor tab, CLI, MCP) uses one set of states, in `state`: `needs-you`, `failed`, `running`, `done`, `starting`, `stopping`, `idle`, `stopped`. `stateLabel` is the display word ("Needs you", "Working", "Running", "Failed · exit 1"). Workspace results carry the most urgent tab's `state` and a `summary` such as "agent · Needs you"; a server that is simply running is steady state and never becomes the summary. The older `status` field is kept for compatibility. A Claude tab whose hooks have not connected is `starting`, or `needs-you` while its trust or login dialog is on screen.

## One-shot commands and waiting

- `mapo.tab.run {tabId?|name,text,lines?,timeoutMs?}` → `{exitCode,output,truncated,durationMs}`. Sends one shell command, waits for shell integration to report it finished, and returns its output (last `lines`, default 200). Rejects when the tab is busy or has no shell integration. The CLI prints the output and exits with the command's exit code.
- `mapo.tab.rename {tabId?|name,newName}` renames a tab; the new name is its label and address.
- `mapo.tab.wait` with a pattern on a shell tab matches only output printed after the last `tab.send`, or after the wait starts when nothing was sent. It never matches the echoed command or older scrollback.

## CLI output

When stdout is a terminal the CLI prints tables, and raw text for `tab read`, `tab run` and `server logs`. When stdout is not a terminal (agents, pipes) it prints compact JSON, as does `--json` anywhere. Errors go to stderr as `mapo: message` on a terminal, JSON otherwise, with a nonzero exit.

Workspace creation accepts an omitted `name` and assigns the first unused `Workspace N` name. `mapo workspace new --json` and MCP `mapo_workspace_create {}` use the same behavior. The header buttons create immediately: New Workspace has no name prompt; New Terminal uses the current/default folder and automatically creates a workspace if needed. Explicit “In Folder…” actions retain their folder picker, and workspaces can be renamed afterward.
