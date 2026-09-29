# Progress

Newest entries first. Every session adds an entry. Every overnight run ends with a **morning report**; its template is in [PLAN.md](PLAN.md). Keep the entries short, link evidence, and move anything that needs the user into "Needs the user".

## 2026-09-29 morning report

Run: started 23:35, written at 04:10 America/Sao_Paulo. The account's usage limit stopped everything from 02:04 to 03:00. Coordinator `mapo-bf`. Code was written on `native` by the coordinator and by its own Opus subagents, 2–3 at a time, each working in its own area of the tree. The four helper sessions' branches were not merged (see Needs the user).

Summary: M0, M1, M2 (synthetic path), M3 (without real Claude) and M4 are built, and every milestone gate drive passes. T5.1 ran once on a Release build. What to try first: `cd ~/code/mapo-native && just app`. You get the S2 rail, tiling panes (⌘D, ⇧⌘D), SwiftTerm terminals served by the daemon that survive ⌘Q and relaunch, ⌘K, Files and Changes (⌥⌘0), and the editor. Try `mapo tab send`, `mapo tab run`, `mapo tab ask` and `mapo mcp` from inside a tab.

### What works
| Area | Status | Gate or drive | Notes |
|---|---|---|---|
| M0: daemon, instances, PTY tabs, zsh integration, `mapo attach`, app skeleton, `mapo ui` | done | m0-skeleton PASS 17/17 | The terminal engine is SwiftTerm, the documented fallback: GhosttyKit acquisition was refused |
| M1: S2 rail, status, tiling panes, switching, Files, editor, ⌘K, keymap table, Mapo Glass | done | m1-daily PASS 16/16; task-t1-1..9 PASS | Find and Go to Line focus fixed at 04:20 |
| M2: plugin, `mapo hook`, agent status machine, agent tabs, interrupt, resume, attention | done on the synthetic path | m2-agents PASS 27/27; task-t2-2, task-t2-4 PASS | No real Claude was run |
| M3: activity log, `tab ask`, `events.wait`, `mapo mcp` (32 tools), skill | done, except the full T3.1 walk | m3-control PASS 9/9; task-t3-5 PASS | `tab ask` verified synthetically only |
| M4: server detection, ports and stop, Changes, diff, gutter | done | m4-servers-changes PASS 27/27 | |
| T5.1: performance pass | first run | m5-switch PASS | Two misses, below |

Evidence folders: `evidence/m0-skeleton/20260929-040132`, `evidence/m1-daily/20260929-040536`, `evidence/m2-agents/20260929-040008`, `evidence/m3-control/20260929-035955`, `evidence/m4-servers-changes/20260929-040201`, `evidence/m5-switch/20260929-034946` (`evidence/` is gitignored and local). Screenshots: none. Pixels were unavailable all night (window occluded, display asleep, Screen Recording not granted), so `docs/progress/` is empty and every visual claim is unverified.

### Metrics against budgets (R-NF-1, Release build unless noted)
| Metric | Budget | Measured | Source |
|---|---|---|---|
| Cold launch to first frame, daemon running | ≤ 400 ms | 396 ms (median of 5) | m5-switch, ui.metrics |
| Reattach and paint | ≤ 150 ms | 270 ms after a daemon restart, including reconnect backoff | m5-switch, app.reattach |
| Switch workspace | ≤ 50 ms | 114 ms p95 with 5 panes each (Release, occluded window); 29 ms p95 (Debug, m1-daily) | navigation workspace.switch |
| Keystroke to glyph against Ghostty | ≤ +2 ms | not measured (T5.3 with you) | |
| Idle CPU, 20 tabs | app ≈ 0, daemon < 0.5 % | both < 0.1 % over 30 s | mapo debug stats |
| Memory, 20 tabs, 10 visible | daemon ≤ 150 MB, app ≤ 250 MB | daemon 14 MB, app 71 MB | mapo debug stats |
| No-op `just build` | < 10 s | 1.5 s | T0.1 |

### Deviations from the docs
See the Deviations table below. The main ones:
- SwiftTerm 1.11.2 instead of GhosttyKit, so `TERM=xterm-256color`.
- Hand-written Swift protocol types instead of typeshare, and hand-written MCP schemas instead of schemars.
- A regex highlighter instead of tree-sitter.
- Waiters live in the tab task.
- `diff.open` is a new method.
- `strip = "none"` in the release profile (Xcode 27's `strip` corrupts proc-macro dylibs).

### Blockers
- Switch p95 over budget on Release: re-measure with the display awake before tuning. The sample shows an idle main thread, so the time is waiting (the daemon round trip and throttled frames of an occluded window).
- `ui.click` now reaches sheets and child panels (fixed 04:15; Save All clicked in the quit sheet saves and quits). A subscriber cut off for falling behind now has its connection closed, so the app reconnects and takes a fresh snapshot. That path is not driven; the ring's cut-off has a unit test.

### Needs the user
Details in the list below:
1. Decide how helper-session work gets integrated (the classifier refused merges), and review or delete the stale helper branches.
2. Allow GhosttyKit, and install the Metal Toolchain.
3. Grant Screen Recording.
4. Allow notifications for Mapo Dev.
5. Run the real-Claude steps of M2 and M3 when usage allows.

### Next task
T5.1 second pass, with the display awake: re-measure switch and reattach on Release, and fix the reattach span to measure app relaunch to painted. Then the Find and Go to Line focus bug, and T3.1's table-driven verb walk. After that, T5.2 and T5.3 with you.

## Needs the user

- **Allow notifications for "Mapo Dev"** when macOS asks (bundle `dev.mapo.app.dev`), or in System Settings › Notifications. Until then drives see `reason=unauthorized`, and the attention log lines still work.
- **Real-Claude drive steps for M2 weren't run tonight.** The account hit its usage limit at 02:04, so the coordinator ran only the synthetic hook path (fixtures through `mapo hook`). With usage to spare, run the M2 real-Claude steps from PLAN §5 (a harmless prompt in `$DRIVE_TMP`, trust, interrupt, resume with PAPAYA).
- **Merging helper branches into `native` is blocked (decide how integration should work).** At 00:05 on 2026-09-29, the coordinator's auto-mode classifier refused to cherry-pick mapo-30's T0.3 commits (`native-daemon`: e8381971bde, 217a57820d7) onto `native` and run their drive, as "Untrusted Code Integration". Nobody retried it or worked around it, and no other session was asked to merge. Earlier, 29d43a8 (mapo-2b's SwiftTerm surface, from `native-surface` 7f190378bee) had already been cherry-picked, built and unit-tested on `native` before the refusal. It is kept; revert it with `git revert 29d43a8` if you prefer. The helpers keep committing on their own branches (`native-daemon`, `native-termcore`, `native-app`, `native-surface`) without cross-merging. To continue, review and merge them yourself (`git merge --ff-only` or `git cherry-pick` in ~/code/mapo-native), or allow the coordinator to integrate helper commits.
- **Allow acquiring GhosttyKit** (the prebuilt libghostty-spm pin from PLAN T0.8, or a Zig 0.16 source build) so T0.8 can move from SwiftTerm to Ghostty (D-13; goal: terminal quality). On 2026-09-28 at 23:40 the coordinator's auto-mode permission classifier refused the prebuilt download as "Untrusted Code Integration". Tonight's run uses the SwiftTerm fallback behind `TerminalSurface`, and nobody retried the download or worked around the refusal.
- **Install the Metal Toolchain?** (`xcodebuild -downloadComponent MetalToolchain`, an Apple component outside Homebrew and cargo, so HANDOFF §6.4 leaves it to you). SwiftTerm 1.12 and later compile a Metal shader and fail without it, so the fallback is pinned to SwiftTerm 1.11.2 (CoreGraphics renderer). Moving to 1.20.0 is a one-line change once it's installed.
- Session `mapo-native` never processed its kickoff: the cross-session message stayed queued and the session stayed "waiting", probably blocked on something in its UI. The overnight run was moved to `mapo-bf` as coordinator (HANDOFF §7). Check what `mapo-native` was waiting on.

- **Screen Recording pre-flight (HANDOFF §4).** On 2026-09-28 at 23:49, `screencapture -x` from the agent's host app (cmux, `com.cmuxterm.app`) exited 0 but produced an all-black image: either Screen Recording isn't granted to cmux, or the display was asleep or locked. Tonight's drives run on semantic snapshots and record `pixels: unavailable`; visual claims are listed under "Not verified". To fix it: System Settings › Privacy & Security › Screen & System Audio Recording › enable cmux, reopen it, and keep the display awake (`caffeinate -dimsu`).

## Deviations

| Task | Spec | Said | Did | Why |
|---|---|---|---|---|
| T0.4 | PLAN T0.4 step 10, ENGINEERING §3.2 `just gen` | Generate Swift types with typeshare | Hand-written Swift types in MapoProtocol, checked against the Rust fixtures; `just gen` runs only XcodeGen | Faster to land tonight with the app track split out; DECISIONS D-15 allows it |
| T0.5 | PLAN T0.5 step 2 and acceptance | `TERM=xterm-ghostty`, `infocmp xterm-ghostty` ok | `TERM=xterm-256color` | No Ghostty terminfo, since GhosttyKit can't be acquired tonight; the code switches automatically once `resources/terminfo/78/xterm-ghostty` exists |
| T0.5 | PLAN T0.5 step 8 | Waiters live in the core | `tab.wait` and `tab.run` waiters live in each tab task, next to the text stream they match | Simpler, with no text copied into the core; the behavior is the same |
| T0.5 | PLAN T0.5 step 8, contract 6 | Match after C only when the send was at a prompt | With shell integration, always match after the next 133;C following the send | A send that races the returning prompt was matched by the tty echo plus zle's redraw of the typed-ahead line |
| T1.2 | UX §4.2 | (M0 showed the next tab) | Closing the tab shown in the only pane leaves an empty pane; with several panes the tab's pane closes | UX §4.2 says so; M0 predated panes |
| T1.2 | ARCHITECTURE §4.3 | Surfaces hide with the view | SwiftTerm `setVisible` is a no-op | Toggling `isHidden` redrew every terminal on the CPU and took the switch p95 to 95 ms |
| T1.4 | UX §4.3 | "Disconnected" scrim on child exit | A stopped tab shows the exit bar ("The shell exited with code N." with Restart and Close Tab) instead of the scrim | Attach now exits on EXIT; the scrim is for a lost daemon |
| T1.5 | UX §2.1 | Inspector segments in the toolbar | Segments sit at the top of the inspector content | The fallback UX §2.1 allows |
| T1.5 | ARCHITECTURE §3.7 | Watching | Non-recursive watches per shown folder, plus a 5 s status cache expiry | Recursive watches on large trees are costly; collapsed subfolders refresh through the expiry |
| M1 | ENGINEERING §4.3 | Panel toggles animate | `toggleSidebar` and `toggleInspector` flip `isCollapsed` directly when the window is occluded | AppKit never finishes the collapse animation for an occluded window, so drives couldn't toggle panels |
| T1.6 | PLAN T1.6, D-14 | Tree-sitter highlighting (SwiftTreeSitter and Neon) | A small in-house regex highlighter (keywords, strings, comments, numbers, types) behind the same interface | Keeps the build free of new packages tonight; tree-sitter can replace it behind the interface |
| T1.7 | UX §10 | SwiftUI palette | The hosting view vends its accessibility children itself | SwiftUI builds its AX tree only for assistive apps, so `ui.tree` couldn't see the field or rows |
| T1.9 | UX §9 | Glass everywhere | `[ui] reduce-transparency = "off"` can't undo the system setting for system glass | System glass follows the system setting |
| T0.8 | PLAN T0.8 fallback | SwiftTerm "from 1.20.0" | SwiftTerm exactly 1.11.2 | 1.12+ needs the Metal Toolchain, which isn't installed (see Needs the user) |
| T0.8 | D-13, PLAN T0.8a | GhosttyKit prebuilt | SwiftTerm fallback, `engine = "swiftterm"` default | GhosttyKit acquisition refused by the permission classifier (see Needs the user) |
| T1.9 | PLAN T1.9 | Write the terminal colors into `ghostty.conf` | `TerminalTheme.ghosttyConfig` renders them; SwiftTerm applies `TerminalTheme` directly and nothing writes the file yet | GhosttyKit isn't linked (see T0.8) |
| T1.9 | PLAN T1.9 acceptance | Compare dark, light and reduced-transparency shots with the boards | `drives/task-t1-9.sh` checks the resolved appearance, title bar, traffic lights, row heights, pane insets and AX labels per variant; tokens are compared with the boards' CSS in `tokens.md`; visuals not verified | No pixels (Screen Recording, occluded window) |
| T1.9 | UX §4.1 | Focused header icon `#C3CBDB` (dark only) | `icon.focused` light is `#2B2E36` (`text.body`) | UX gives no light value |

## 2026-09-28/29 overnight run (coordinator mapo-bf)

- **Set Agent Command… and the rail's workspace menu (04:25).** Set Agent Command… (Workspace menu, palette, rail) opens the UX §3.5 sheet "Agent command for <workspace>". Its field shows the current command, fully selected, with the placeholder "claude" and the note. Save is disabled while the field is empty and calls `workspace.configure` through a new `MapoClient.setAgentCommand`. The rail's workspace menu gains New Tab in Folder… and Set Agent Command…, and New Tab in Folder… now takes the workspace it came from. New row in `task-t1-8`: the sheet shows `echo fakeagent`, Save is disabled once the field is cleared, and saving `echo second-agent` shows in `workspace list`. 79/79, evidence `evidence/task-t1-8/20260929-042422`. Not driven: the rail context menu itself, because `mapo ui` can't open context menus (their tracking loop is modal). The items call the same paths the menu bar drives.
- **Find and Go to Line focus fixed (04:20).** Closing the find bar makes the window itself first responder, and AppKit then picks the next key view, often the terminal in the other pane. The pane area now remembers which pane's find UI (a field or its field editor) last had focus. When focus leaves it without a person's command, it goes back to that pane's content instead of focusing the other pane. New step in `task-t1-6`: ⌘F then Escape, and ⌘L then Escape, both keep `editor:<path>` focused. 15/15, evidence `evidence/task-t1-6/20260929-041802`. Regressions: `task-t1-8` 74/74, `m1-daily` 16/16.
- **Fixes after the gates (04:02–04:06).**
  - The Files segment keeps the last tab's folder while a file or diff pane has focus (R-FS-2). New step in `task-t1-5`, 18/18.
  - `ui.key`'s action router now sends a menu action to the focused view when that view handles it, before looking for a controller up the chain.
  - Still open (time-boxed at 20 min): with the window inactive, ⌘F in an editor opens a find bar whose field isn't in `ui.tree`, and closing it leaves focus on the terminal pane. Go to Line (⌘L) shows no `editor.goToLine` element. Next idea: check whether `window.sendEvent` of Escape reaches the find bar while the window isn't key, and give the find field an identifier.
- **T4.3 done** (subagent) and **T4.4: M4 gate PASS.**
  - **T4.3:**
    - `git.status`, `git.diff` and `git.baseText` via the git CLI (`-c core.fsmonitor=false --no-optional-locks`).
    - The Changes segment has a summary, rows with letters and +/- counts, the warning above 1,500 lines or 50 files, and states.
    - A new `diff.open` method (a deviation: PROTOCOL had no way to show a diff pane) opens a read-only unified `pane.diff:<absPath>` with Open File.
    - The editor's git gutter is diffed against HEAD with `CollectionDifference`, debounced at 200 ms (`editor.gutter:<path>`).
    - `task-t4-3` PASS 16/16: diff opens in 141 ms, commit to empty list 479 ms, gutter after an edit 271 ms.
  - **M4 gate:** `just drive m4-servers-changes` PASS 27/27, evidence `evidence/m4-servers-changes/20260929-040201`. It combines Changes, diff and gutter with server detection, ports and a guarded stop.
  - Open (found by the subagent): while a file or diff pane has focus, the Files segment re-roots to `no-terminal` instead of keeping the last focused tab's folder (R-FS-2). Changes works around it; Files doesn't yet.
  - Every drive re-passed on one integration build: M0, M1, M2 and M3 gates, T1.5, T1.6, T1.8, T2.2, T3.5, T4.1, T4.3.
- **T5.1 performance pass (first run, Release build).** `just profile=release drive m5-switch` PASS, evidence `evidence/m5-switch/20260929-034946`. Fixture: 20 tabs, 10 visible (two workspaces of 5 panes each after `seq 1 2000`, plus 10 hidden tabs).

  | Metric | Budget | Measured (Release) |
  |---|---|---|
  | Cold launch, daemon running, median of 5 | ≤ 400 ms | 396 ms |
  | Workspace switch p95 of 20, 5 panes each | ≤ 50 ms | 114 ms (miss; see below) |
  | Reattach after a daemon restart | ≤ 150 ms | 270 ms (miss; includes reconnect backoff) |
  | Attach replay (daemon side) | | 4 ms |
  | Idle CPU over 30 s | app ≈ 0, daemon < 0.5 % | both < 0.1 % |
  | Footprint | daemon ≤ 150 MB, app ≤ 250 MB | daemon 14 MB, app 71 MB |

  - The switch miss: a `sample` of the app during 60 switches shows the main thread mostly idle (mach_msg), so the time is waiting on the daemon round trip and frame presentation. The window was occluded all night (display asleep), which throttles frames, so re-measure with the display awake before tuning. The Debug runs measured 29–37 ms with 3 panes.
  - The reattach miss: the span runs from losing the connection to synced, so it includes the app's reconnect backoff (250 ms first step). The budget means reattaching an app to a running daemon; measure that as relaunch-to-painted in the next pass.
  - Keystroke latency against Ghostty wasn't measured (T5.3, with the user).
  - Fixed on the way: Release builds failed ("mis-aligned LINKEDIT string pool" in proc-macro dylibs), because Cargo's default release `strip` corrupts dylibs with this machine's Xcode 27 `strip`. `[profile.release] strip = "none"`.
- **T3.7: M3 gate PASS** (synthetic). `m3-control` PASS 9/9, evidence `evidence/m3-control/20260929-034450`. A shell tab acting as an agent, with its own `MAPO_TOKEN`, creates tab B, runs a command, waits on output, reads the screen, is refused closing B, closes it with `--force`, finds both in the activity log, and lists tabs through `mapo mcp`. The real-Claude `tab ask` and MCP-from-Claude steps are skipped (usage limit).
- **T3.5 done** (subagent). `mapo mcp` on rmcp `=3.5.0` exposes 32 tools, with strict hand-written schemas (a deviation from schemars), plus `mapo://skill`. It requires `MAPO_TOKEN` and exits 0 when stdin closes. Drive `task-t3-5` PASS 18/18.
- **T4.1 and T4.2 done** (coordinator; `crates/mapo-proc` on libproc `=0.14.11`). Ports are scanned on 133;C and D, then at 1, 2 and 5 s, then every 10 s while the command runs; idle tabs are never scanned. `TabSummary.server.ports`. A server exiting non-zero is failed ("exit N"), but Ctrl-C (130) and SIGTERM (143) count as intentional stops. `proc.ports`, `mapo ports` (maps listeners to tabs by TTY or ancestry), `proc.stop` and `mapo process stop` (identity re-check, refuses Mapo's own processes, SIGTERM only, needs `--force` from agents). Drive `task-t4-1` PASS 11/11: detection within about 1 s.
- **T3.1 partial (parity check by hand).** Every VS Code build verb for a v1 feature exists with the same name: `workspace new|list|rename|activate|delete|move|configure`, `tab new|list|close|rename|focus|move|send|read|wait|run|ask|stop|interrupt|restart`, `status`, `events`, `activity`, `ports`, `process stop`, `file open`, `pane …`, `explorer …`, `skill`, `mcp`, `hook`, `attach`, `ui …`. The absent verbs belong to features out of v1: `setup`, `repo`, `action`/`actions`/`run` and `mprocs` (D-3), `server` (D-20), and `pin`/`unpin` (R-WS-8, LATER). Not done: the table-driven drive over every verb, and grouping `mapo --help` by noun.
- **T2.6: M2 gate PASS on the synthetic path.** `just drive m2-agents` PASS 27/27, evidence `evidence/m2-agents/20260929-033827`. It covers every R-AG-3 transition through `mapo hook`, attention while hidden, rail and dock badges, the notification log with coalescing, ⌘J, interrupt from the pane's Stop and ⇧⌘X, ⇧⌘T, and Working and Done in the rail and pane. The real-Claude path is skipped with its reason recorded (usage limit).
- **T2.4 done** (app side by a subagent).
  - **What's in it:**
    - dock badge (needs-you count, "99+")
    - `rail.workspace.badge:<ws>` as an AX element
    - notifications per UX §7.3, with identifier `<instance>/<tabId>`, lazy authorization, the `notification:<tabId> … reason=` log line, and click-to-focus
    - ⌘J to the next attention tab
    - ⇧⌘T for agent tabs; ⇧⌘X and the agent pane's Stop interrupt
    - `dockBadge` in the snapshot model
  - The daemon re-announces `tab.state` (`previous == state`) when a hook repeats an attention state, so the app logs `coalesced`.
  - Drive `task-t2-4` PASS 23/23, evidence `evidence/task-t2-4/20260929-033443`. The keymap drive now covers ⇧⌘T, ⌘J and ⇧⌘X (74/74).
  - Notification permission for `dev.mapo.app.dev` was never granted, so the first line logs `reason=unauthorized` (see Needs the user).
- **M3 control-plane pieces done** (coordinator):
  - **T3.2:** migration 0003, an activity log bounded to 5,000 rows, `activity.list`, `mapo activity` and `activity.recorded`. Every mutating request from an agent tab or `ui.*` is recorded with outcome ok, error or rejected. Checked: from tab A, `mapo tab close B` is rejected (exit 1, "must pass --force"), `--force` closes it, and both appear in the log with caller `tab`.
  - **T3.3:** `tab.ask` and `mapo tab ask`. It waits for idle or done, pastes the prompt, confirms UserPromptSubmit within 10 s, waits for done and returns the Stop's `last_assistant_message`. The message is held only until the ask takes it, and new `tab.hook` events carry metadata only. Synthetic check: the reply "OK" exits 0; a permission request mid-turn exits 5 with `needs_you`.
  - **T3.4:** `events.wait` long poll, which returned `{events: []}` after 526 ms for a 500 ms timeout.
  - **T3.6:** the ported skill in `plugin/skills/mapo/SKILL.md`, printed by `mapo skill` byte for byte.
  - Not done: T3.1 (a full verb parity walk), T3.5 (`mapo mcp` on rmcp) and T3.7 (the M3 gate).
- **M2 daemon side: T2.1, T2.2, T2.3 and T2.5 done, synthetic path.**
  - **Plugin:** `plugin/` has the manifest, `hooks.json` for the ten R-AG-3 events, `.mcp.json` and a stub skill. It's embedded in the bundle as `Resources/claude-plugin`, and every tab gets `CLAUDE_CODE_PLUGIN_DIRS`, appended to any existing value.
  - **`mapo hook`:** reads up to 1 MiB, keeps only `hook.report`'s fields, logs only to `hook.<date>.log`, and always exits 0 within 2 s.
  - **`hook.report`:** hook credentials are separate tokens bound to their own tab and may only call `hook.report`. It feeds the FEATURE-MAP §5.1 status machine (`crates/mapo-agent`, table tests), whose state wins over the shell's. Needs-you details read "Approve: …". Optimistic Working on a send reverts after 6 s. Agent state resets when the agent's command ends.
  - **Commands:** `attention.changed`; `tab.interrupt` (Escape, then late events ignored); `workspace.configure --agent-command`; agent tabs type the agent command into the shell.
  - **Resume:** migration 0002 persists `session_id`, and after a restart the tab relaunches with `--resume <id>`.
  - Also: a tab's launch command now counts as pending, so idle waits don't return before it ran.
  - Drive `task-t2-2` PASS 18/18, evidence `evidence/task-t2-2/20260929-032345`.
  - Not run: the real-Claude steps (T2.1 `hooksConnected` from real Claude, T2.3 a real interrupt, T2.5 PAPAYA). They would spend the shared usage that cut the night short (see Needs the user).
- **T1.10 done: M1 gate PASS.** `just drive m1-daily` PASS 16/16 (8 steps), evidence `evidence/m1-daily/20260929-031518`.
  - Measured: launch 430 ms and relaunch 430 ms (Debug; budget 400 in release), pane.split 10 ms, workspace-switch p95 29 ms (budget 50), daemon reconnect 233 ms, app.reattach after a daemon restart 273 ms (budget 150; the span includes reconnect backoff), footprints daemon 12 MB and app 97 MB.
  - Fixed on the way: ⌘Q through `ui.key` ran the quit inside the automation handler, so the unsaved-files sheet's modal loop blocked every later `ui.*` call. The quit now runs on the next run-loop turn.
  - Open: focus after closing Find or Go to Line moves to another pane. (`ui.click` into sheets was fixed later.)
- **T1.6 to T1.9 done** (written by subagents; two of them died at 02:04 on the shared usage limit, and the coordinator finished their work after 03:00). Every drive passes on one integration build, and so do all the M0 and T1.1–T1.5 drives:
  - **T1.6 editor:**
    - `task-t1-6` 12/12, `evidence/task-t1-6/20260929-030640`.
    - file.open splits beside the terminal and focuses `editor:<path>`; typing plus ⌘S saves.
    - Folders and broken links are rejected with the layout unchanged. Images preview in the file pane.
    - A 2,000-line file opens in 60 ms (budget 100).
    - A clean buffer reloads external changes; a dirty one offers keep-mine and reload. Unsaved text survives a workspace switch.
    - Not driven: crash recovery with `editor.restore`, find and replace, Go to Line.
  - **T1.7 palette:**
    - `task-t1-7` 21/21, `evidence/task-t1-7/20260929-030410`; palette.open 12 ms.
    - The coordinator fixed a gap: SwiftUI builds its accessibility tree only for assistive apps, so the palette's hosting view now lists its field, rows (`palette.row:<i>`) and the "No matches" text itself.
  - **T1.8 keymap:**
    - `task-t1-8` 70/70, `evidence/task-t1-8/20260929-030959`: one command table builds the menus, the palette's commands and the drive's checklist. Every UX §8 shortcut is driven, or marked with its milestone (M2: agent tab, interrupt, ⌘J).
    - The drive focuses tabs by clicking rail rows, because a CLI `tab.focus` never moves keyboard focus (by design).
  - **T1.9 appearance:**
    - `task-t1-9` 20/20, `evidence/task-t1-9/20260929-030213`: dark, light and forced Reduce Transparency via `config.toml [ui]`.
    - Checked: title bar hidden, traffic lights inside the rail, row heights, AX labels unchanged.
    - Every token matches the boards (table in that evidence folder's `tokens.md`).
    - All pixels not verified.
- **M0 critical review (Fable) and fixes.** The review found five clear bugs, all fixed and re-driven (T0.3 to T0.6 drives pass):
  1. A stopped tab's `mapo attach` looped forever. EXIT now ends attach with code 3; attaching to a stopped tab fails at once with `conflict`; the host drops a stopped shell's handle.
  2. Closing a tab didn't hang up its shell, because the PTY read half kept the master open. Close now aborts the read task, and the shell is gone within 0.3 s instead of the 3 s SIGKILL.
  3. `tab wait --until TEXT` after input sent into a running program (a REPL, `cat`) never matched. Such sends now match after their echo; sends at a prompt, or typeahead that meets a prompt, still match after 133;C.
  4. The attach outbound queue was unbounded. A client more than 1 MiB behind stops getting output and is resynced with a fresh replay once it drains (PROTOCOL §8).
  5. Tab credentials weren't guarded (R-CTL-4). Closing another tab or deleting a workspace from a tab needs `force`, and `ui.*`, `explorer.*` and attach need the app credential.

  Also done:
  - emulator scrollback cut to 2,000 lines (the R-NF-1 budget)
  - RESIZE clamped to 1000×500
  - `LaunchSpec` Debug redacts the token
  - idle waits on shells without integration fail fast with `unavailable`
  - request tasks abort when their client disconnects
  - the instance lock retries for 2 s (restart race)
  - SQLite `busy_timeout`

  Still open (recorded, not fixed): a mid-stream `cursor_expired` goes out with a null id, which the app drops (it recovers on its next reconnect); SQLite write failures are logged but not surfaced as events.
- **T1.1 to T1.5 done** (rail by a subagent; layout and switching by a subagent; Files by a subagent; the T1.1 and T1.4 daemon parts and the integration by the coordinator). Every drive passes on one integration build:
  - `task-t1-1` 28/28 `evidence/task-t1-1/20260929-013935`: 24 and 26 pt rows, Couldn't start, branch in the workspace row, persisted reorder, inline rename, delete keeps the scroll position.
  - `task-t1-2` 25/25 `evidence/task-t1-2/20260929-014152`: pane.split 70 to 78 ms; the layout survives relaunch and a daemon restart, ratios included.
  - `task-t1-3` 11/11 `evidence/task-t1-3/20260929-013950`: warm switch p95 30 ms, p50 24 ms over 40 switches; hidden surfaces detach after 30 s and repaint when shown.
  - `task-t1-4` 8/8 `evidence/task-t1-4/20260929-014038`: a long unviewed command becomes failed (stateDetail "exit 1") or done; a short one stays idle; failed clears on the next command; Stop gives exit 130; a stopped shell restarts in its folder.
  - `task-t1-5` 16/16 `evidence/task-t1-5/20260929-014202`: rows with git letters, gitignore honored, following cd in 133 to 190 ms without taking focus, missing, empty and unreadable states.

  M0 still passes (`m0-skeleton` 17/17). Reviews: accept, with every visual claim unverified (no pixels).

  Known gaps, listed for the morning:
  - Rail context menus can't be driven: `ui click --right` opens a real NSMenu whose tracking loop blocks `ui.*`. The items exist but are unexercised.
  - Drag reorder and gutter dragging can't be driven: `mapo ui` has no drag verb. Move Up and Move Down, and `pane.resize`, are driven instead.
  - Switching back to a workspace whose surfaces were freed takes about 230 ms, because 5 surfaces are rebuilt and reattached.
  - The rail's `applyStructure` costs about 10 ms per switch in Debug; it goes on the T5.1 list.
- **T0.10 done (isolation proof).** Setup was a fresh worktree `../mapo-native-iso` (`native-iso`): `just setup` took under 5 s, and its cold `just build` took 27 s while main rebuilt in 6 s. Both instances ran at once:

  | | dev-mapo-native | dev-mapo-native-iso |
  |---|---|---|
  | Window title | "… (dev-mapo-native)" | "Only-Iso (dev-mapo-native-iso)" |
  | Workspaces | Alpha, Only-Main | Only-Iso |
  | Socket, lock, pid files | `dev-mapo-native.*` | `dev-mapo-native-iso.*` |
  | Data dir | `…/instances/dev-mapo-native` | `…/instances/dev-mapo-native-iso` |

  Results:
  - Nothing listens on TCP.
  - `just kill` in iso stopped only iso; main kept answering ping.
  - `just app` rebuilt and restarted only the app; the shell's pid stayed 62093.
  - `just drive m0-skeleton` passed 17/17 in the fresh worktree too (P4).
  - The worktree, its instance and its branch were removed afterwards.

  GhosttyKit cache reuse is not applicable tonight.
- **T0.11 done: M0 gate PASS.** `just drive m0-skeleton` PASS 17/17 (9 steps), evidence `evidence/m0-skeleton/20260929-010224`:
  - ⇧⌘N 86 ms, ⌘T to first prompt 207 ms (the user's zsh startup), launch 260 ms, relaunch 260 ms, app.reattach 271 ms after a daemon restart, attach replay 2 ms
  - footprints with 3 tabs: daemon 10.6 MB, app 123 MB
  - vim survives ⌘Q and relaunch, and the terminals keep their pids

  The drive reads the "Reconnecting to mapod…" banner from the app log (`banner reconnecting: …`), since `ui.*` goes through the daemon that is down at that moment. `lib.sh` gained `wait_app`. Review: accept.
- **T0.9 done** (the app side by an Opus subagent under review). `app.register`; the daemon routes `ui.*` to the most recently registered app with string ids, adds `terminals` to snapshots and `attach.lastMs` to metrics, and fails waiting calls as soon as the app disconnects (so ⌘Q doesn't hang for 10 s). MapoAutomation implements tree, snapshot, click (mouse-up posted first), press, focus, key (US key codes, the menu first), type, wait, window and metrics, all in process with no Accessibility permission. Identifiers are on every M0 control, plus `window.divider:*` and `pane.empty.newShell` (added to ENGINEERING §4.2), and the identifier check prints 0. Also `mapo ui`, `just snap` and the `lib.sh` app, snapshot and screenshot helpers. Drive `task-t0-9` PASS 8/8, evidence `evidence/task-t0-9/20260929-010005`: launch 423 ms (debug), new workspace 83 ms, new tab 51 ms. Review: accept. When the app isn't key, `ui.key` sends a matched menu item's action along the responder chain itself, because AppKit's key-equivalent path does nothing for an inactive window.
- **T0.8 done on the SwiftTerm fallback.** The surface (29d43a8, by mapo-2b before the merge refusal) is hosted in the pane and runs `Contents/Helpers/mapo attach`. Drive `task-t0-8` PASS 6/6, evidence `evidence/task-t0-8/20260929-005943`: one attach process per visible surface, typing reaches the shell, ⌘T reaches the menu, and vim survives ⌘Q and relaunch with a clean prompt afterwards. Not verified: resizing (an occluded window can't run the inspector animation) and all pixels. Also fixed: `tab.wait --until idle` right after a send made while a command still ran returned early (the typed-ahead line hadn't started yet); a prompt that typeahead is queued behind now stays non-idle for 250 ms or until the command's 133;C.
- **T0.7 done** (Swift side written by an Opus subagent under the coordinator's review; the coordinator removed a signal-driven debug command runner it had added, since `mapo ui` covers that in T0.9). What's in it:
  - `MapoWindow`, the split view (glass rail sidebar, panes, collapsed inspector), programmatic menus, AXID, the S2 rail bound to an `@Observable` AppStore, and `app.banner` states.
  - `MapoConnection` (NWConnection over the unix socket, NDJSON), `MapoClient` (hello, snapshot, subscribe, backoff, respawning the daemon), `DaemonLauncher`, the app pid file, and hand-written MapoProtocol types checked against the Rust fixtures.
  - `just app`.

  Checked by hand on `dev-mapo-native`:
  - `just app` spawned the daemon and logged `connected bootId=…`; `app.connected` is event seq 1.
  - The terminal surface ran `Contents/Helpers/mapo attach` for the tab.
  - After `mapo instance stop`, the app respawned the daemon within about 50 ms and took a fresh snapshot. The rail repopulated, and the surface's attach reconnected on its own.
  - Nothing listens on TCP, and no token appears in the logs. The daemon uses 10 MB and the app 61 MB.

  The subagent also checked ⇧⌘N, ⌘T, rail clicks and the banner states against a live daemon. `mapo ui` drives these again in T0.9. Pixel evidence is unavailable.
- **T0.6 done.** The attach frame codec (`mapo-protocol::frames`, tested with frames split at every size); attach sessions in the daemon (replay then live output, input, resize, ping and pong, resync on lag, EXIT with a flush, DETACH on shutdown); raw replay from the byte ring with queries stripped, or grid replay rendered from the emulator (`MAPO_REPLAY=grid`, and automatically when the switch into the alternate screen was trimmed), both ending in a mode trailer; `mapo attach --tab T` with raw mode, SIGWINCH, keepalive, 30 s of reconnect with backoff, a fresh `app.token` on each attempt, and hidden `--replay-only` and `--size`. `app.connected` and `app.disconnected` events are emitted. Drive `task-t0-6` PASS 11/11, evidence `evidence/task-t0-6/20260929-003258`. Review: accept.
- **T0.5 done.** Tabs are login shells in daemon-owned PTYs (`pty-process`), with the zsh integration written in-house (`resources/shell-integration/zsh/`, tested against the user's real rc files including starship: A/B/C/D with exit codes, OSC 7, titles, PATH fix-up). `mapo-term` has an OSC pre-parser with a text stream, the 2 MiB ring with escape-safe cuts, the replay query stripper, `tab read` rows, and the tab task (alacritty emulator, detached query answers, launch commands, title throttling). The core launches tabs on create, on daemon start and when focus retries a failed launch; per-tab tokens authenticate the `tab` credential; exit 0 after the first prompt closes the tab and anything else leaves it stopped. New: `tab.send|read|wait|run` and their CLI verbs. Drive `task-t0-5` PASS 17/17, evidence `evidence/task-t0-5/20260929-002454`: tab ready in 377 ms, footprint 36 MB after a 4 MB flood, tab read in 27 ms. Review: accept. A drive-harness bug is fixed too: zsh skips the EXIT trap when errexit fires inside a function, so `lib.sh` also traps ZERR.
- **T0.4 done** (daemon side). `mapo-core`: the actor that owns state, the pure `status` function (table test), default names, SQLite in WAL with numbered migrations on its own writer thread, and the 10,000-event ring with `cursor_expired` and cut-off for slow subscribers. Methods: `state.snapshot`, `events.subscribe`, `workspace.list|create|rename|activate|delete`, `tab.list|create|close|rename|focus`. CLI: `workspace …`, `tab list|new|close|rename|focus`, `status`, `events [--follow] [--after] [--type]`, global `--workspace`. Protocol fixtures are in `crates/mapo-protocol/fixtures/` with a Rust round-trip test. Drive `task-t0-4` PASS 17/17, evidence `evidence/task-t0-4/20260929-001106`: names, conflict and not_found errors, ordered events, focus activating the workspace, state surviving a daemon restart, forced delete. Review: accept. Swift protocol types are hand-written instead of generated by typeshare (see Deviations).
- **T0.3 done** (written on `native` by the coordinator, after the helper merge refusal). Protocol envelope, error kinds and hello types in `mapo-protocol`; `mapo daemon [--foreground]` (flock, pid file, token, 0600 socket bound under umask 0177, uid check, hello gate, ping, instance.info, daemon.shutdown, SIGTERM and SIGINT, 60 s socket check); `mapo rpc`, `mapo debug stats`; `instance wait` now pings, `stop` sends daemon.shutdown first, and `show` fills in bootId and protocol. Drive `task-t0-3` PASS 14/14, evidence `evidence/task-t0-3/20260929-000255`: daemon-ready 48 ms, stop 69 ms, idle CPU 0.0 % over 2 s, footprint 5.8 MB, no token in the logs. Review: accept. `daemon.stopping` is emitted once the event ring exists (T0.4).
- **T0.2 done.** `crates/mapo-instance` (names, resolution from the executable's worktree, paths, 0700 dirs, pid files, `Secret` tokens, process identity through `proc_pidpath` and `KERN_PROCARGS2`); `mapo instance show|list|wait|stop|clean`; `just mapo`, `just kill` and `just clean-instance`; `drives/lib.sh` stage 1 with the `DRIVE_NO_APP=1` knob (added to ENGINEERING §5.2). Evidence by hand, as PLAN allows for T0.2: every acceptance line holds. The worktree default is `dev-mapo-native`, `MAPO_INSTANCE` gives `source: env`, `Bad_Name` exits 2 and quotes the regex, the executable decides the name even from `/tmp`, `--instance main instance clean` exits 1, the runtime dir is mode 700, the socket path is 74 bytes (limit 91), `just instance=main kill` exits 1, and 8 unit tests pass. `instance wait` checks for a connectable socket until T0.3 adds `ping`, and `instance stop` uses SIGTERM, then SIGKILL, until T0.3 adds `daemon.shutdown`.
- **T0.1 done.** Cargo workspace, crate stubs, MapoKit (6 modules plus tests), XcodeGen app, justfile, mprocs.yaml, embed script. `just setup` exits 0 and reports zig and sccache as optional; `just build` exits 0; `Contents/Helpers/mapo --version` prints `mapo 0.1.0`; codesign shows `Identifier=dev.mapo.app.dev` with `flags=0x10002(adhoc,runtime)`; a no-op `just build` takes 1.5 s; `git status` is clean of generated files. Xcode drops the hardened-runtime flag for ad-hoc signing, so `project.yml` passes `OTHER_CODE_SIGN_FLAGS = --options runtime`.
- **Parallel tracks** (HANDOFF §7): mapo-30 has the daemon (T0.3 to T0.6, `native-daemon`); mapo-02 has termcore, the pure T0.5/T0.6 pieces and the zsh integration (`native-termcore`); mapo-07 has the app (T0.7, T0.9, `native-app`); mapo-2b has the terminal surface on SwiftTerm (T0.8, `native-surface`). The coordinator does T0.1, T0.2, the merges, T0.10 and T0.11.

## 2026-09-28: specs written, no code yet

- The interview produced [DECISIONS.md](DECISIONS.md). The design exploration is on the Claude Design canvas <https://claude.ai/artifact/DXzWX7bnxWX3i2zJCy1A8J>; the chosen boards are "A · Source list" and "S2 · Slimmer".
- Research is saved in [research/](research/).
- The orphan branch `native` was created as worktree `~/code/mapo-native`. The docs set was written and committed.
- Next: [PLAN.md](PLAN.md) T0.1.
