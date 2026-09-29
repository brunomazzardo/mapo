# Mapo native: protocol v1

One protocol serves the app, the CLI, MCP, hooks and automation. The daemon is the only server. This document is the contract. `crates/mapo-protocol` implements it, and the Swift types are generated from that crate.

## 1. Transport

- **Socket.** A Unix domain socket at `<runtime dir>/<instance>.sock`, where the runtime dir is `$(getconf DARWIN_USER_TEMP_DIR)mapo/`. The directory is mode 0700 and the socket 0600. Instance names match `[a-z0-9][a-z0-9-]{0,31}`, which keeps the path under the 104-byte limit.
- **Control connections.** UTF-8 JSON, one JSON-RPC 2.0 message per line (NDJSON). Requests may be pipelined, and responses can arrive out of order, matched by `id`.
- **Attach connections.** These start like control connections (one `hello` line). After the successful response, the stream switches to binary frames (§8).
- **Peer check.** On accept, the daemon rejects peers whose uid differs from its own (`getpeereid`).

## 2. Handshake

The first message on every connection must be `hello`.

```json
{"jsonrpc":"2.0","id":1,"method":"hello","params":{
  "protocol":1, "role":"cli", "client":"mapo/0.1.0",
  "credential":{"kind":"tab","token":"<MAPO_TOKEN>"}
}}
```

```json
{"jsonrpc":"2.0","id":1,"result":{
  "protocol":1, "daemon":"0.1.0", "bootId":"0199a3c2-7f1e-7c4a-9b1d-3e2f5a6b7c8d", "instance":"dev-mapo-native",
  "features":["events","attach","ui","hooks","git","proc"],
  "caller":{"kind":"tab","tabId":"0199a3c2-…","workspaceId":"0199a3c1-…"}
}}
```

- **Roles:** `app`, `cli`, `mcp`, `hook`, `attach`.
- **Protocol mismatch.** A mismatched `protocol` gets the error `unavailable` with `data.daemonProtocol`. The app then offers "Restart Daemon".
- **Evolution is additive only.** New methods, optional fields and event types don't bump `protocol`, and clients ignore unknown fields and events. A breaking change bumps `protocol`.

## 3. Credentials and caller identity

| Credential | Where it comes from | Caller | Rights |
|---|---|---|---|
| `app` | `<instance data dir>/app.token` (0600, regenerated each daemon boot) | operator (the user or a driving agent) | Everything. Destructive calls still require `force` when not interactive. |
| `tab` | `MAPO_TOKEN` in a tab's environment | that tab | Everything scoped to the caller's workspace by default. `force` is needed to delete workspaces, close other tabs or stop processes. |
| `hook` | `MAPO_HOOK_TOKEN` in a tab's environment | that tab's hook | Only `hook.report` for its own tab. |

- The `mapo` CLI picks its credential in this order:
  1. `MAPO_TOKEN`, used only when `MAPO_INSTANCE` equals the resolved instance, so `--instance other` from inside a tab doesn't send the wrong tab's token
  2. otherwise the app token of the resolved instance, read from its data directory
  3. otherwise it fails with an actionable message.
- `attach` connections present the `app` credential, read from `app.token` on every connect attempt, since tokens rotate when the daemon boots.
- Tokens are 32 random bytes, base64url-encoded. They are never logged, echoed, included in events or activity, or passed as argv.
- Closing a tab revokes its tokens, and a daemon restart issues new ones.

## 4. Requests, results, errors

- **Params.** Always an object. Unknown fields are rejected with `invalid_argument`, so typos fail loudly.
- **Errors** look like this:

  ```json
  {"code":-32001,"message":"Tab \"be-agent\" not found in workspace \"Obsess\"",
   "data":{"kind":"not_found","hint":"mapo tab list --workspace Obsess","details":{}}}
  ```

| `kind` | JSON-RPC code | Meaning | CLI exit |
|---|---|---|---|
| `invalid_argument` | -32602 | Bad or unknown params | 2 |
| `not_found` | -32001 | Selector matched nothing | 1 |
| `conflict` | -32002 | Ambiguous name, duplicate name, or wrong state | 1 |
| `forbidden` | -32003 | Missing `force`, or credential not allowed | 1 |
| `unavailable` | -32004 | No app connected (for `ui.*`), no shell integration, protocol mismatch | 1 |
| `busy` | -32005 | Tab is running a command (`tab.run`) or another operation holds it | 1 |
| `timeout` | -32006 | A wait expired | 124 |
| `cancelled` | -32007 | The client disconnected, or the user cancelled a confirmation | 1 |
| `needs_you` | -32008 | The target agent needs the user (`tab.ask`) | 5 |
| `internal` | -32603 | Bug. Includes a log reference. | 1 |

How the CLI prints errors:
- **Piped, or with `--json`:** one line on stderr, `{"error":"<message>","kind":"<kind>","hint":"<hint>"}`. This keeps the VS Code build's `error` field (PA-40).
- **On a terminal:** `mapo: <message>`, followed by the hint on a second line when there is one.

## 5. Selectors and resolution

- IDs are UUIDv7 strings.
- `workspace` accepts a name or an ID. Workspace names may repeat; an ambiguous name returns `conflict` with the candidate IDs.
- `tab` accepts a name or an ID. Tab names are unique within a workspace. A name resolves in:
  1. the `workspace` param, if present
  2. otherwise the caller's workspace (`tab` credential)
  3. otherwise the active workspace (`app` credential).
- With a `tab` credential, an omitted `tab` means the caller's own tab (PA-39).
- A name that doesn't resolve returns `not_found`, with `data.details.names` listing the workspace's tab names.
- `kind` accepts the aliases `terminal` (→ `shell`) and `claude` (→ `agent`). Results always use `shell` and `agent`.
- Paths are absolute on the wire. The CLI resolves relative paths against its own working directory.
- `pane` is a pane ID; omitted means the focused pane of the resolved workspace.

## 6. Methods

The milestone is where each method first ships ([PLAN.md](PLAN.md)). "→" means the result.

### 6.1 Meta, state, events, activity

| Method | Params → result | M |
|---|---|---|
| `hello` | §2 | M0 |
| `ping` | `{}` → `{bootId, uptimeMs}` | M0 |
| `instance.info` | `{}` → `{instance, dataDir, runtimeDir, socket, daemonPid, version, protocol, configError?}` | M0 |
| `daemon.shutdown` | `{}` → `{stopping:true}`. Operator only. Tabs are relaunched from their definitions on next start. | M0 |
| `state.snapshot` | `{}` → `{seq, bootId, activeWorkspaceId, workspaces:[WorkspaceSummary], tabs:[TabSummary], layouts:{<wsId>:Layout}}` | M0 |
| `events.subscribe` | `{after?:seq, types?:[string]}` → `{seq}`, then notifications `{"method":"event","params":Event}` | M0 |
| `events.wait` | `{after:seq, timeoutMs?}` → `{events:[Event], cursor}` (MCP long-poll) | M3 |
| `activity.list` | `{limit?:100, before?:id}` → `[Activity]` | M3 |

### 6.2 Workspaces

| Method | Params → result | M |
|---|---|---|
| `workspace.list` | `{}` → `[WorkspaceSummary]` | M0 |
| `workspace.create` | `{name?}` → `WorkspaceSummary` (the default name is the first free "Workspace N") | M0 |
| `workspace.rename` | `{workspace, name}` → `WorkspaceSummary` | M0 |
| `workspace.activate` | `{workspace}` → `WorkspaceSummary` | M0 |
| `workspace.delete` | `{workspace, force?}` → `{deleted:true}`. With running foreground programs, `forbidden` unless `force`. | M0 |
| `workspace.move` | `{workspace, index}` → `WorkspaceSummary` (zero-based; out-of-range is `invalid_argument`, nothing changes) | M1 |
| `workspace.configure` | `{workspace, agentCommand?}` → `WorkspaceSummary` | M2 |

### 6.3 Tabs

| Method | Params → result | M |
|---|---|---|
| `tab.list` | `{workspace?}` → `[TabSummary]` | M0 |
| `tab.create` | `{workspace?, name?, kind?:"shell"\|"agent", cwd?, command?, agentCommand?, placement?:"focused"\|"right"\|"down"\|"background", focus?:bool}` → `TabSummary`. `cwd` defaults to the focused tab's cwd, then `$HOME`. `command` runs in the interactive shell after the first prompt. | M0 |
| `tab.close` | `{tab, workspace?, force?}` → `{closed:true}` | M0 |
| `tab.rename` | `{tab, workspace?, name}` → `TabSummary` | M0 |
| `tab.focus` | `{tab, workspace?}` → `TabSummary`. Activates its workspace and shows the tab: in its own pane if visible, otherwise in the focused pane, or in the most recently focused terminal pane when the focused pane shows a file or diff. Retries a failed launch. | M0 |
| `tab.restart` | `{tab, workspace?}` → `TabSummary`. Restarts a `stopped` tab's shell in its last cwd (R-TAB-12). | M1 |
| `tab.move` | `{tab, workspace?, index}` → `TabSummary` | M1 |
| `tab.send` | `{tab, workspace?, text, execute?:true, paste?:auto}` → `{sent:<bytes>}`. `execute` appends Enter. `paste` uses bracketed paste for multi-line text. | M0 |
| `tab.read` | `{tab, workspace?, lines?:200}` → `{tabId, text, altScreen, cursor:{row,col}}`. Includes populated rows below the cursor and drops trailing blank rows. | M0 |
| `tab.wait` | `{tab, workspace?, until:"idle"\|{pattern}, timeoutMs?:600000}` → `TabSummary`. Patterns match output after the last `tab.send`, or after the wait began. | M0 |
| `tab.run` | `{tab, workspace?, command, lines?:200, timeoutMs?}` → `{exitCode, output, truncated, durationMs}`. Needs OSC 133 and an idle shell (`busy` otherwise). | M0 |
| `tab.stop` | `{tab, workspace?}` → `TabSummary`. Sends Ctrl-C to the foreground job. | M1 |
| `tab.interrupt` | `{tab, workspace?}` → `TabSummary`. Sends Escape to an agent and records the interrupt. | M2 |
| `tab.ask` | `{tab, workspace?, prompt, timeoutMs?:1800000}` → `{reply, turnMs}`, or `needs_you` | M3 |

### 6.4 Layout and panes

| Method | Params → result | M |
|---|---|---|
| `layout.get` | `{workspace?}` → `Layout`. Every `pane.*` method also accepts an optional `workspace`. | M1 |
| `pane.split` | `{pane?, direction:"right"\|"down", content?:{tab}\|{file}\|"new-shell"}` → `Layout` | M1 |
| `pane.close` | `{pane?}` → `Layout`. The tab keeps running in the background. | M1 |
| `pane.focus` | `{pane?}` or `{direction:"left"\|"right"\|"up"\|"down"}` → `Layout` | M1 |
| `pane.resize` | `{split, ratios:[number]}` → `Layout` | M1 |
| `pane.equalize` | `{workspace?, split?}` → `Layout`. `split` equalizes one split (a double-click on its gutter). `pane.focus` rejects `pane` and `direction` together; `pane.split {tab}` moves a tab already shown elsewhere by closing that pane first. | M1 |

### 6.5 Files, explorer, git

| Method | Params → result | M |
|---|---|---|
| `file.open` | `{path, workspace?, beside?:true}` → `{path, paneId}`. Existing regular files only; folders, missing paths, broken links and unreadable files are rejected before any UI change. | M1 |
| `fs.list` | `{path}` → `{path, state:"ready"\|"empty"\|"missing"\|"unreadable", hiddenByExclude:number, repo?:{root, branch?}, entries:[{name, kind:"file"\|"dir"\|"symlink", git?:"M"\|"A"\|"D"\|"R"\|"?"\|"U", ignored?:bool}]}`. `kind` follows a symlink's target; `symlink` means a broken link. `hiddenByExclude` counts `[files] exclude` matches only. | M1 |
| `fs.watch` / `fs.unwatch` | `{path}` → `{}`. Connection-scoped and non-recursive: one folder's entries plus the repository's `HEAD`, `index` and refs. Emits `fs.changed {root, paths}` (entry names; empty when the folder itself changed) and `git.changed {root}`. | M1 |
| `explorer.refresh` / `explorer.collapse` | `{}` → `{path, state}` (routed to the app) | M1 |
| `git.status` | `{path}` → `{root, branch, head?, upstream?, ahead, behind, files:[{path, status, added, deleted, binary?:true}], totals:{files, added, deleted}, warn?:string}`. `path` is any folder or file in the repository; `not_found` outside one. `branch` is null when detached, and `head` is HEAD's short id (absent before the first commit). `files` is one list sorted by path, with staged, unstaged and untracked files together; `status` uses the `fs.list` letters, and an untracked file counts its lines as added. `warn` appears above `[changes] warn-lines` (1,500) or `warn-files` (50). | M4 |
| `git.diff` | `{root, path}` → `{text}`: `git diff -U3` of one file against HEAD (staged and unstaged); an untracked file diffs against nothing. `path` is absolute or relative to `root`. | M4 |
| `git.baseText` | `{path, root?}` → `{text, rev}`; `not_found` when HEAD doesn't have the file (untracked, added, no commit) or outside a repository | M4 |
| `diff.open` | `{root, path, workspace?}` → `{path, paneId}`. Shows `path`'s diff (`{diff:{root, path}}`, both absolute) in the workspace's file pane, placed like `file.open`, and leaves focus where it is (UX §5.3). | M4 |

### 6.6 Processes

| Method | Params → result | M |
|---|---|---|
| `proc.ports` | `{port?}` → `[{pid, identity, executable, ports:[u16], tabId?, protected:bool}]` | M4 |
| `proc.stop` | `{pid, identity, force?}` → `{signalSent:true, pid}`. Stale identity is `conflict`; a protected process is `forbidden`. | M4 |

### 6.7 Agents, hooks, notifications

| Method | Params → result | M |
|---|---|---|
| `hook.report` | `{event:string, sessionId?, source?, cwd?, transcriptPath?, agentId?, notificationType?, promptId?, toolName?, toolSummary?, lastAssistantMessage?}` → `{accepted:true, state}`. Hook credential only. `toolSummary` is at most 80 characters (a Bash command or a file path) and is kept only while the tab is `needs-you`. | M2 |
| `notify` | `{message, tab?}` → `{shown:bool}` (routed to the app) | M2 |

### 6.8 App registration and automation (`ui.*`)

Every `ui.*` method is routed to the most recently registered app of the instance. With no app registered it fails with `unavailable`.

| Method | Params → result | M |
|---|---|---|
| `app.register` | `{capabilities:["ui"], version}` → `{}`. App credential only. | M0 |
| `ui.visibility` | `{keyWindow:bool, visibleTabIds:[id], focusedTabId?}` → `{}`. App to daemon. | M1 |
| `ui.window` | `{}` → `{windowNumber, frame:{x,y,w,h}, scale, title, occluded:bool, appearance:"dark"\|"light", reduceTransparency:bool, increaseContrast:bool, titleBarHidden:bool, trafficLights:{x,y,w,h}\|null}`; `trafficLights` is in window points, top-left origin (T1.9) | M0 |
| `ui.tree` | `{depth?:12, root?:Target}` → `Element` (§7) | M0 |
| `ui.snapshot` | `{}` → `{window, focus?:ElementRef, tree:Element, model:{workspaceId, layout, rail:[...]}, terminals:[{tabId, paneId, text}]}` | M0 |
| `ui.click` | `{target, button?:"left"\|"right", count?:1, modifiers?:[..]}` → `{ok:true, element}` | M0 |
| `ui.press` | `{target}` → `{ok:true}` (accessibility press action) | M0 |
| `ui.focus` | `{target}` → `{ok:true}` | M0 |
| `ui.type` | `{text}` → `{ok:true}` (key events to the first responder) | M0 |
| `ui.key` | `{chord:"cmd+t"\|"cmd+shift+n"\|"escape"\|…, phase?:"press"\|"down"\|"up"}` → `{ok:true}` (goes through menus and key equivalents; `down`/`up` let a drive hold ⌘ to reveal shortcut hints) | M0 |
| `ui.wait` | `{target, state?:"exists"\|"gone"\|"focused"\|"enabled", timeoutMs?:5000}` → `{element}` | M0 |
| `ui.hover` | `{target}` → `{ok:true, element, hovered:[string]}`. Moves the synthetic mouse to the middle of the target (a rail or Files row is scrolled into view first): tracking-area owners it left get `mouseExited`, those it reached get `mouseEntered` (and `mouseMoved` when they ask), and hover stays until the next `ui.hover`. `hovered` names the owners now under the mouse by identifier, else by class. | M1 |
| `ui.scroll` | `{target, dy}` → `{ok:true, element}`. One pixel-unit scroll-wheel event over the middle of the target's visible part. `dy` is in points; positive scrolls the content down (reveals what is below, like dragging the scroller down), negative up. | M1 |
| `ui.metrics` | `{reset?:bool}` → `{launch:{processStartToFirstFrameMs}, navigation:[{name, ms}], frames:{p50Ms, p95Ms, dropped}, attach:{lastMs}}` | M0 (basic) / M5 (full) |

A `Target` is one of:
- `{"id":"rail.tab:Obsess/be-agent"}`: an accessibility identifier from the scheme in ENGINEERING §4
- `{"label":"be-agent"}`
- `{"role":"button","label":"New Tab"}`
- `{"point":{"x":10,"y":20}}`

All `ui.*` coordinates are window-relative points with the origin at the top left. An `ElementRef` is `{id?, role, label?, frame}`. Targets resolve by model identity, and virtualized rows in the rail and the Files tree are scrolled into view before a click (PA-36).

## 7. Shared types

```text
WorkspaceSummary { id, name, order, agentCommand, activeTabId?, state, stateLabel, summary, attentionCount, tabCount, branch? }
TabSummary       { id, workspaceId, name, labeled, title, kind, order, cwd, launch:{cwd, command?, agentCommand?},
                   state, stateLabel, stateDetail?, statusSource, program?, visible, paneId?,
                   agent?:{hooksConnected, sessionId?}, server?:{ports:[u16]}, lastExit?:{code, durationMs},
                   launchError?:{kind, message, path?} }
Layout           { workspaceId, focusedPaneId, root: Node }
Node             { kind:"split", id, axis:"row"|"column", ratios:[number], children:[Node] }
               | { kind:"pane", id, content:{tab:id}|{file:path}|{diff:{root,path}}|{empty:true}, recentFiles:[path] }
Event            { seq, bootId, at, type, data }
Activity         { id, at, caller:{kind, tabId?, name?}, command, target?, outcome:"ok"|"error"|"rejected", error? }
Element          { id?, role, label?, value?, frame:{x,y,w,h}, focused, enabled, children:[Element] }
```

`state` is one of `needs-you`, `failed`, `running`, `done`, `starting`, `stopping`, `idle`, `stopped`. `stateLabel` is the display word from REQUIREMENTS R-ST-1.

### Event types

| Type | `data` |
|---|---|
| `workspace.created`, `workspace.updated`, `workspace.moved` | `WorkspaceSummary` |
| `workspace.deleted` | `{id}` |
| `workspace.activated` | `{id}` |
| `tab.created`, `tab.updated`, `tab.moved` | `TabSummary` |
| `tab.closed` | `{id, workspaceId}` |
| `tab.state` | `{tabId, workspaceId, state, previous, stateLabel, source}`. Emitted in addition to `tab.updated` when the state changes. |
| `layout.updated` | `Layout` |
| `attention.changed` | `{count, tabIds:[id]}` |
| `fs.changed` | `{root, paths:[string]}` |
| `git.changed` | `{root}` |
| `activity.recorded` | `Activity` |
| `app.connected`, `app.disconnected` | `{}` |
| `daemon.stopping` | `{reason}` |
| `config.error` | `{path, message}`. `config.toml` failed to parse, and the last good settings stay in force (PA-43). |

- The ring keeps the last 10,000 events.
- `events.subscribe {after}` with an `after` older than the ring is an error: kind `conflict`, with `data.details.reason = "cursor_expired"`.
- After reconnecting to a daemon with a new `bootId`, a client must take a fresh `state.snapshot`.

## 8. Attach connections

1. The client sends `hello` with `role:"attach"`, the app credential, and `params.attach = {tab, cols, rows, widthPx, heightPx}`.
2. The daemon replies with `{..., "attach":{"tabId", "replayBytes"}}` and switches to frames:

```
frame := kind:u8 | length:u32 big-endian | payload[length]      (payload ≤ 65536 bytes)

0x01 OUT           daemon → client   terminal output bytes
0x02 IN            client → daemon   input bytes (already encoded by the terminal)
0x03 RESIZE        client → daemon   cols:u16 rows:u16 widthPx:u16 heightPx:u16
0x04 REPLAY_BEGIN  daemon → client   (empty) followed by OUT frames with the replay
0x05 REPLAY_END    daemon → client   (empty)
0x06 EXIT          daemon → client   code:i32 (the tab's shell exited; the tab shows it and may restart)
0x07 PING, 0x08 PONG  either way     (empty) keepalive every 15 s
0x09 DETACH        either way        (empty) orderly close
```

- More than one client may attach to a tab. Output goes to all of them, input from any of them is accepted, and size follows the last `RESIZE` sent.
- A client that falls more than 1 MB behind gets a fresh `REPLAY_BEGIN` resync instead of dropped bytes.
- With zero clients, the daemon's emulator answers terminal queries (ARCHITECTURE §3.4).

## 9. CLI mapping

| CLI | Method |
|---|---|
| `mapo workspace list\|new [NAME]\|rename NAME NEW\|activate NAME\|delete NAME --force\|move NAME --index N\|configure NAME --agent-command CMD` | `workspace.*` |
| `mapo tab list\|new [--name N] [--kind shell\|agent] [--cwd DIR] [--cmd CMD] [--placement …]` | `tab.list`, `tab.create` |
| `mapo tab send NAME TEXT… [--no-execute]`, `read NAME [--lines N]`, `wait NAME --until idle\|TEXT [--timeout-ms N]` | `tab.send`, `tab.read`, `tab.wait` |
| `mapo tab run NAME COMMAND…`, `ask NAME PROMPT…`, `stop NAME`, `interrupt NAME`, `restart NAME` | `tab.run`, `tab.ask`, `tab.stop`, `tab.interrupt`, `tab.restart` |
| `mapo tab focus\|close\|rename\|move NAME …` | `tab.*` |
| `mapo pane split right\|down [--tab NAME\|--file PATH] [--pane ID]`, `pane focus left\|right\|up\|down` (or `--pane ID`), `pane close [--pane ID]`, `pane equalize` (all honor `--workspace`) | `pane.*` |
| `mapo tab stop NAME`, `mapo tab restart NAME`, `mapo tab move NAME --index N`, `mapo workspace move NAME --index N` | `tab.stop`, `tab.restart`, `tab.move`, `workspace.move` |
| `mapo status [NAME]` | `tab.list`/`workspace.list` filtered |
| `mapo file open PATH` | `file.open` |
| `mapo explorer refresh\|collapse` | `explorer.*` |
| `mapo git changes [PATH]` | `git.status` |
| `mapo ports [--port N]`, `mapo process stop PID --identity ID --force` | `proc.ports`, `proc.stop` |
| `mapo notify MESSAGE` | `notify` |
| `mapo events --follow [--after SEQ]`, `mapo activity` | `events.subscribe`, `activity.list` |
| `mapo ui window\|tree\|snapshot\|click\|press\|focus\|type\|key\|wait\|hover\|scroll\|metrics` | `ui.*` |
| `mapo daemon [--foreground]`, `mapo attach --tab ID`, `mapo hook`, `mapo mcp`, `mapo skill` | (process modes) |
| `mapo instance show\|list\|wait\|stop\|clean` | client-side: resolved paths, known instances, wait for the socket, `daemon.shutdown`, delete an instance's data (ENGINEERING §2) |
| `mapo debug stats\|latency` | client-side: process CPU/RSS of the daemon and app, round-trip and attach latency probes (ENGINEERING §6) |
| `mapo rpc METHOD [JSON]` | any method, raw: prints the JSON result. For drives and debugging. |

Global flags: `--instance NAME` (defaults to `MAPO_INSTANCE`, then the worktree default in ENGINEERING §2), `--workspace NAME|ID`, `--json`, `--timeout-ms N`.

## 10. MCP mapping

- `mapo mcp` connects with the tab credential from its environment. It requires `MAPO_TOKEN` and never falls back to the app token: without it, it exits 1 with a clear message (PA-41). Closing its stdin cancels outstanding waits and exits 0.
- It exposes one tool per public method in §6.1–§6.7, named `mapo_<group>_<verb>` (for example `mapo_tab_ask` and `mapo_workspace_create`), plus `mapo_events_wait` and the resource `mapo://skill`.
- `ui.*`, `app.*`, `hook.*` and `daemon.*` are not exposed.
- Tool input schemas are generated from the protocol types and reject unknown properties.
- Failures set `isError`. Successes return JSON text plus `structuredContent.result`.
- Descriptions stay under 2,048 characters.
