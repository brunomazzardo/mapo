# Mapo native: UX specification

Status: approved direction, 2026-09-28. This document says how Mapo looks and behaves. [REQUIREMENTS.md](REQUIREMENTS.md) says what it must do (R-* IDs are cited throughout), [ARCHITECTURE.md](ARCHITECTURE.md) §4 describes the app modules, and [PROTOCOL.md](PROTOCOL.md) defines the command behind every action. It is based on the chosen canvas boards (§12) and on the Mapo Glass theme of the frozen VS Code build.

Sizes are points; one canvas px is one pt. Colors are the tokens in §9. Quoted strings are exact UI copy, and a string that itself contains double quotes is shown in backticks. AppKit builds everything here except the ⌘K palette, which is SwiftUI in an `NSPanel` (ARCHITECTURE §4.2).

## 1. Design principles

Each rule can be checked in a drive, a screenshot or a code review.

| ID | Rule |
|---|---|
| Calm-1 | Status never animates: no spinners, pulses or bounces for tab or workspace state. A spinner may appear only for a blocking load over 300 ms, such as Files loading or reconnecting. |
| Calm-2 | Background events never move keyboard focus, change a selection, scroll a list or reorder rows (REQUIREMENTS §8.3). A user action scrolls only as far as needed to reveal its target. |
| Calm-3 | A shell command's `running`, and every `starting` and `stopping`, renders only after it has lasted 500 ms. Agent Working renders at once. |
| Quiet-1 | Chrome is neutral gray. Color means state (§7), diff or syntax. `accent` marks keyboard focus, selection and links, nothing else. The only sound is the default notification sound for needs-you and failed. |
| Quiet-2 | The rail writes words only for urgent states: "Needs you", "Failed", "Couldn't start". Other states are 6 pt dots or nothing, and a rail row has one trailing accessory at most. |
| Quiet-3 | Actions show only while they apply. Stop shows only while something runs. A terminal pane's close button shows only on hover. A control whose action is in flight shows a pending state and ignores repeated clicks (PA-25). |
| Quiet-4 | Expected failures (a missing folder, a failed launch, a file that won't open or save) appear as a non-blocking message with a recovery action, never a modal error (PA-27). Confirmations are in-window sheets that drives can answer (PA-35). |
| Dense-1 | Fixed heights: rail tab row 24, rail workspace row 26, tree and change rows 26, palette rows 32, pane headers 36. Chrome text runs from 10.5 to 15 pt, with nothing larger than the toolbar title. Metadata shares one line, joined by " · ". |
| Keys-1 | Every action is in the menu bar with its shortcut (§8) and in the palette (§10). Esc closes every overlay (palette, rename field, sheet, find bar) and returns focus to the view that had it. |
| Keys-2 | Opening a file focuses the editor. Creating a tab focuses its terminal. Closing a pane focuses the pane that takes its space. The terminal receives every key that is not a menu key equivalent. |
| Native-1 | System components first: `NSSplitViewController` sidebar and inspector items, `NSToolbar`, `NSOutlineView`, `NSMenu`, `NSAlert`, `NSOpenPanel`, `NSTextFinder`, `UNUserNotificationCenter`, `NSDockTile`. No private API and no titlebar hacks. The traffic lights stay where AppKit puts them. |
| Native-2 | Liquid Glass appears only on the rail, the inspector, toolbar items and overlays; panes are opaque (R-NF-6). Appearance, Reduce Motion, Reduce Transparency and Increase Contrast apply live, without a relaunch (R-NF-5). |
| Drive-1 | Every interactive element has an accessibility identifier (§2.4 and [ENGINEERING.md](ENGINEERING.md) §4.2). Its VoiceOver label names it and speaks its state. |

## 2. Window anatomy: "A · Source list"

Tasks T0.7 and T1.9. Each instance has one main window, `MapoWindow: NSWindow`, identified as `window.main`.

```text
 rail: sidebar item, glass  toolbar band, then panes on the backdrop         inspector, glass
+-------------------------+                                                 +----------------------+
| o o o      [=]  [+]     | Obsess         [|][-]  [Go to... Cmd-K]  [>]    | [ Files | Changes 3 ]|
|                         | 5 tabs . backend, frontend                      |                      |
| Workspaces              | +-----------------------+ +-------------------+ | ~/code/obsess [br x] |
| v Obsess rate-limit (1) | |* be-claude [Needs you]| |# session.ts Diff x| | v src                |
|   * be-claude Needs you | |-----------------------| |-------------------| |   v auth             |
|   * fe-claude         o | | terminal              | |1 | import {...    | |       session.ts    M|
|   = api           :4000 | +-----------------------+ +-------------------+ |   > lib              |
|   = web          Failed | +---------------------------------------------+ | > test              o|
|   $ zsh                 | |= api  o Running    localhost:4000      Stop | |   package.json       |
| > Mapo                o | |---------------------------------------------| |                      |
| > Site                o | | terminal                                    | |                      |
| > Dotfiles              | +---------------------------------------------+ |----------------------|
|                         |                                                 |3 changed files +87 -6|
+-------------------------+                                                 +----------------------+
 legend: * agent  $ shell  = server  o 6 pt dot  (1) badge  [=] sidebar toggle  [+] new workspace
         [|][-] split capsule  [>] inspector toggle  [br x] branch chip  # file  v > chevrons
```

- **Window.** Style mask `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]` with `titlebarAppearsTransparent = true`, `titleVisibility = .hidden` and `toolbarStyle = .unified`, so there is no title bar (R-NF-6). The toolbar band keeps its system height, about 52, and has no background. Empty toolbar space drags the window. The first launch opens a centered 1440×900 window; the frame autosaves as `main-<instance>`; the minimum size is 760×480.
- **Title.** `NSWindow.title` is the active workspace name, with ` (<instance>)` appended for every instance except `main`. The toolbar hides it, but Mission Control, the Window menu and `ui.window` use it.
- **Structure.** An `NSSplitViewController` holds the rail (`NSSplitViewItem(sidebarWithViewController:)`), the panes area (the content item) and the inspector (`NSSplitViewItem(inspectorWithViewController:)`). A layer-backed view at the bottom of the content view paints `backdrop` (§9.1), which shows through the toolbar band, the pane gutters and the glass.

### 2.1 Toolbar

| # | Item | Identifier | Spec |
|---|---|---|---|
| 1 | Flexible space | | Pushes items 2 and 3 to the trailing edge of the rail section. |
| 2 | `.toggleSidebar` | `rail.toggle` | `sidebar.left`. Tooltip "Hide Sidebar (⌃⌘S)". |
| 3 | New Workspace | `rail.newWorkspace` | `plus`. Tooltip "New Workspace (⇧⌘N)". |
| 4 | `.sidebarTrackingSeparator` | | |
| 5 | Title | `toolbar.title` | Two lines, 1 pt apart. The workspace name in 15 semibold `text.primary`, then the subtitle in 12 `text.secondary`: "5 tabs · backend, frontend", which lists the distinct basenames of the tabs' folders in tab order, three at most, then "+N". Other forms: "1 tab · backend", "No tabs". Every instance except `main` starts the subtitle with its name in `accent`: "dev-mapo-native · 5 tabs · backend". |
| 6 | Flexible space | | |
| 7 | Split group, a momentary `NSToolbarItemGroup` | `toolbar.splitRight`, `toolbar.splitDown` | Two 34×26 segments in one 32-tall capsule, `rectangle.split.2x1` and `rectangle.split.1x2`. Tooltips "Split Right (⌘D)" and "Split Down (⇧⌘D)". |
| 8 | Palette button | `toolbar.palette` | 300×32. `magnifyingglass` 14, "Go to tab, file or command" in 13 `text.secondary`, and "⌘K" in 12 `text.secondary` at the trailing edge. Shrinks to 180 wide, then to a 32×32 icon (`visibilityPriority = .low`). |
| 9 | `.toggleInspector` | `toolbar.inspector` | `sidebar.right`. Tooltip "Hide Inspector (⌥⌘0)". |
| 10 | `.inspectorTrackingSeparator` | | |
| 11 | Inspector segments | `inspector.segment:files`, `inspector.segment:changes` | §5.1. Hidden while the inspector is collapsed. |

macOS draws the glass capsules around toolbar items, so do not paint the canvas's `rgba(255,255,255,0.06)` capsule fills. If the inspector tracking separator misplaces item 11, move the segment control to the top of the inspector content, 50 pt below its top edge, and note it in PROGRESS.md. Glyph names in this document are SF Symbols unless §3.1 says otherwise.

### 2.2 Sizes and resizing

| Region | Default | Min | Max | Behavior |
|---|---|---|---|---|
| Rail | 280 (`[ui] rail-width`) | 220 | 400 | Keeps its width when the window resizes. ⌃⌘S collapses it. |
| Panes area | the rest | 400 | | Absorbs window resizes. Panes sit 10 from the rail, the inspector and the window bottom, and 4 below the toolbar band. |
| Inspector | 300 (`[ui] inspector-width`) | 240 | 520 | ⌥⌘0 collapses it. |
| Pane | | 200×120 | | 8 pt gutters between panes. |

Both side items set `canCollapseFromWindowResize = true`. When the panes area would drop below 400, the inspector collapses first, then the rail. Split view autosave, named `split-<instance>`, keeps widths and collapsed states per instance; the config values only seed a new instance. With the rail collapsed, items 2 and 3 move next to the traffic lights, which is AppKit's default.

### 2.3 Materials

The rail and the inspector get system Liquid Glass from their split view items. Their content views stay clear (no `NSVisualEffectView`, no fill) and set `prefersCompactControlSizeMetrics = true`. In a `just snap` screenshot the inspector must read as the same material as the rail; if it does not, wrap the inspector root in `NSGlassEffectView` with cornerRadius 14. Panes are opaque `pane` cards (§4). §9.4 lists every material and its Reduce Transparency fallback.

### 2.4 Identifiers added by this document

ENGINEERING §4.2 holds the base scheme and its rules. This document adds `window.divider:rail` and `window.divider:inspector` (the split view's dividers), `pane.divider:<splitId>/<index>` (pane gutters), `pane.header:<absPath>` (file and diff headers), `pane.showDiff:<absPath>`, `pane.openFile:<absPath>`, `pane.recent:<paneId>`, `pane.preview:<absPath>`, `pane.openURL:<tabName>`, `pane.retry:<tabName>`, `pane.reconnect:<tabName>`, `pane.empty.newShell:<paneId>`, `pane.empty.newAgent:<paneId>`, `rail.rename`, `rail.empty.newWorkspace`, `inspector.files.state`, `inspector.files.retry`, `inspector.files.footer`, `inspector.changes.state`, `inspector.changes.retry`, `inspector.changes.warning`, `editor.keepMine:<absPath>`, `editor.reload:<absPath>`, `editor.restore:<absPath>`, `editor.discard:<absPath>`, `editor.openDefault:<absPath>`, `editor.reveal:<absPath>`, `editor.retrySave:<absPath>`, `editor.close:<absPath>`, `dialog.field`, `dialog.discard`, `dialog.kind`, `dialog.choose`, `app.banner`, `app.banner.action`, `app.notice` and `app.notice.action`. Elements that carry a state expose the raw state string as their AX value, for example `needs-you` on a tab row or `missing` on `inspector.files.state`.

## 3. Rail: "S2 · Slimmer"

Tasks T0.7 (basic rows) and T1.1. The rail is a view-based `NSOutlineView` in an `NSScrollView` inside the sidebar item, identified as `rail` with the AX label "Workspaces". It uses `rowSizeStyle = .custom`, zero intercell spacing, `indentationPerLevel = 0` and no system disclosure triangle. Row views draw their own indents, chevrons and backgrounds with radius 6. The list inset is 0 at the top, 8 at the sides and 8 at the bottom.

### 3.1 Rows

| Row | Height | Padding, leading / trailing | Contents, leading to trailing |
|---|---|---|---|
| Header | 24 | 10 / 10 | "Workspaces" in 11 semibold `text.secondary`. Not selectable. |
| Workspace | 26 | 10 / 10 | Chevron 11 in `icon` (`chevron.down` when expanded, `chevron.right` when collapsed), gap 7, name in 13 semibold (`text.primary` when active, else `text.body`), gap 7, branch in 11.5 `text.secondary` (takes the free width and truncates first), accessory. The expanded workspace's last tab is followed by a 6 pt gap. |
| Tab | 24 | 26 / 10 | Kind icon 12 in `icon`, gap 8, display name in 12.5 `text.body` with tail truncation, accessory, then the ⌘ hint column (§3.3). |
| "No tabs" | 24 | 26 / 10 | 12.5 `text.secondary`, when the active workspace has no tabs. Not selectable. |

- **Workspace accessory.** The active workspace shows a badge when some of its tabs need you, and nothing otherwise. A collapsed workspace shows the badge in the same case; failing that, a 6 pt dot in its most urgent state's color (R-WS-7) when that state is `failed`, `running` or `done`. A serving tab never sets the workspace's state or summary (R-WS-7, PA-34). The badge (`rail.workspace.badge:<workspaceName>`, AX label "1 needs you" or "2 need you") is 16 tall and at least 16 wide, with padding 0 4, radius 8, fill `needs.fill` and 10.5 bold monospaced digits in `#1D1F25`.
- **Branch.** Every workspace row with a known `WorkspaceSummary.branch` shows it (R-WS-5). A detached HEAD shows its 7-character SHA. Outside a repository the slot stays empty.
- **Display name.** A labeled tab shows its name. An unlabeled tab shows its live title (R-TAB-3), which arrives without Claude's spinner and ✳ glyphs because the daemon strips them (PA-38). An empty title falls back to the name.
- **Kind icon.** The agent sparkle when `kind` is `agent` or `agent` is set; agent tabs never switch to the server icon. The server stack when `server.ports` is non-empty, which lasts until the next command starts (ARCHITECTURE §3.6). The shell prompt otherwise. These three are template images traced from the canvas: viewBox 24×24, no fill, stroke 1.8, round caps and joins. Sparkle paths: `M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z` and `M19 16l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z`. Prompt paths: `M5 7l5 5-5 5` and `M12 18h7`. Server stack: `rect x4 y4 w16 h7 rx2`, `rect x4 y13 w16 h7 rx2`, `M8 7.5h.01` and `M8 16.5h.01`.

Tab accessories, highest priority first:

| Tab state | Accessory | Name color |
|---|---|---|
| needs-you | "Needs you" in 11.5 `needs` | `needs.tint` |
| failed | "Failed" in 11.5 `failed` | `failed.tint` |
| failed with a launch error | "Couldn't start" in 11.5 `failed` | `failed.tint` |
| running while serving | ":4000" in 11.5 `text.secondary`, or ":4000 +1" with more ports | `text.body` |
| running (Working, Running) | 6 pt dot, `running` | `text.body` |
| done | 6 pt dot, `done` | `text.body` |
| starting, stopping | 6 pt dot in `text.secondary`, after 500 ms | `text.body` |
| stopped | 6 pt ring, stroke 1.5, `stopped` | `text.secondary` |
| idle | none | `text.body` |

### 3.2 Row states

| State | Look |
|---|---|
| Hover, pressed | Fill `hover`, fading in over 120 ms, and `pressed` while the mouse is down. Rows have no inline actions (D-16). |
| Selected | Fill `selection`, icon `icon.selected`, name `text.primary` unless tinted. On the selected row, `text.secondary` becomes `text.secondaryOnSelection` and the "Failed" word becomes `failed.tint`, for contrast (§9.1). |
| Keyboard focus | While the rail is first responder, the selected row also gets a 1 pt inner stroke of `accent` at 60%. Mouse-only use never shows it. |
| Tooltip | Tab: its `~` cwd, such as "~/code/obsess/backend", plus " · {stateDetail}" when set. Workspace: its summary (§7.2), or "5 tabs" when the summary is empty. |

The selected row is the tab in the focused pane of the active workspace. When that pane holds a file or a diff, the last focused tab keeps the selection, because the inspector still follows it. A focused empty pane leaves nothing selected.

### 3.3 Hold-⌘ hints (R-KEY-3)

Holding ⌘ alone for 400 ms while the window is key shows "⌘1" to "⌘9" on the first nine tab rows of the active workspace, whichever view has focus. They sit in a 22 pt right-aligned column after the accessory, in 11 `text.secondary`, or `text.secondaryOnSelection` on the selected row. The name truncates to make room; row heights never change. Releasing ⌘, pressing another key, clicking, or the window resigning key hides them. They fade over 120 ms, or switch instantly under Reduce Motion. A local `flagsChanged` monitor reads ⌘ and never consumes the event. VoiceOver does not announce the hints.

### 3.4 Interaction

| Input | Result |
|---|---|
| Click a tab | `tab.focus`, which shows the tab (R-LAY-3). Its terminal takes focus. |
| ⌥-click a tab | Show to the Right (§3.5). |
| Click a collapsed workspace | `workspace.activate`. It expands, the previous workspace collapses, and the scroll offset shifts so the clicked row stays under the pointer. Clicking the active workspace does nothing. |
| ↑ ↓ with the rail focused | Moves the selection. A tab shows as soon as it is selected. |
| Return, →, ← | Return on a tab moves focus into its pane. Return or → on a collapsed workspace activates it. ← on a tab selects its workspace row. |
| Type letters with the rail focused | Type-to-select: the next row whose workspace name or tab display name starts with them (PA-30). |
| ⌥⌘R, or double-click a name | The name turns into a text field (`rail.rename`) in the same font, with a 1 pt `accent` border, radius 4 and the text selected. It validates while typing (PA-28): an empty name, or a tab name already used in the workspace, gets a `failed` border and a tooltip naming the problem, and Return does nothing until it is fixed. Return commits through `tab.rename` or `workspace.rename`. Esc, an unchanged value, or clicking away while invalid cancels; clicking away while valid commits. If the daemon still rejects the name, the field stays open with its message. Renaming an unlabeled tab makes it labeled (R-TAB-3). |
| ⌘⌫ | Close Tab or Delete Workspace, with the §3.5 confirmations. |
| Drag a row | Tabs reorder within their own workspace (`tab.move`), and workspaces reorder among workspace rows (`workspace.move`). Drop feedback is `.gap`, or `.regular` under Reduce Motion. A drop onto another workspace is refused with no indicator, and the row snaps back. Esc cancels. The list autoscrolls at its edges. |

### 3.5 Context menus and confirmations

- Workspace row: New Shell Tab · New Agent Tab · New Tab in Folder… | Rename · Set Agent Command… | Move Up · Move Down | Delete Workspace
- Tab row: Rename · Copy Name · Copy Path · Reveal in Finder | Show to the Right · Show Below | Interrupt Agent · Stop Command · Open in Browser · Retry Launch | Move Up · Move Down | Close Tab
- Empty rail area: New Workspace

`|` marks a separator. Some items are hidden unless they apply. Interrupt Agent needs a working agent, Stop Command a running command, Open in Browser a serving tab (one "Open localhost:{port}" item per port), and Retry Launch a tab that couldn't start. Show to the Right and Show Below need a tab that is not visible; they call `pane.split` with `content:{tab}`. Move Up and Move Down hide at the ends of the list. Copy Path copies the tab's cwd. Drives target menu items as `{"role":"menuItem","label":...}`.

Confirmations and small forms are sheets on the main window (`NSAlert.beginSheetModal(for:)` or a sheet view controller), never app-modal panels (PA-35). They use `dialog`, `dialog.field`, `dialog.confirm` and `dialog.cancel`, and a destructive confirm button sets `hasDestructiveAction`. Cancel at any step changes nothing.
- Delete Workspace first resolves the workspace's unsaved files with Save, Don't Save or Cancel (PA-24). It then asks only when a tab runs a foreground program (R-WS-1): `Delete "Obsess"?` / "2 tabs are still running programs (claude, npm). Deleting the workspace stops them and closes its 5 tabs." / [Delete Workspace] [Cancel].
- Close Tab asks per R-TAB-7: `Close "api"?` / "npm is still running in this tab. Closing the tab stops it." / [Close Tab] [Cancel].
- Set Agent Command… is titled "Agent command for Obsess", with a field (placeholder "claude"), the note "New agent tabs in this workspace run this command in your shell, so aliases like claude-work work." and [Save] [Cancel]. Save, disabled while the field is empty, calls `workspace.configure`.
- New Tab in Folder… is titled "New tab in folder". Its path field holds the focused tab's `~` cwd, fully selected so typing replaces it (PA-28), and validates while typing ("No folder at ~/code/x." disables the confirm button). It also has a pop-up "Shell" / "Agent" (`dialog.kind`), [Choose…] (`dialog.choose`, an `NSOpenPanel` sheet for folders), and [New Tab] [Cancel].

### 3.6 Empty states

With no workspaces, the rail shows "No workspaces" in 12.5 `text.secondary` under the header, followed by a borderless "New Workspace" button (`rail.empty.newWorkspace`). The panes area then shows "Create a workspace to start." and a primary [New Workspace]. ⌘T and ⇧⌘T work there too: they create the first free "Workspace N" and open the tab in it (PA-23). A workspace keeps existing when its last tab closes (PA-22); it then shows the "No tabs" row, an empty pane (§4.4) and the inspector's no-terminal states.

### 3.7 Scrolling and focus (REQUIREMENTS §8)

1. Only the active workspace is expanded (R-WS-4). Background events never change that.
2. Status, title and port changes repaint rows in place. They never scroll, reorder or move the selection (REQUIREMENTS §8.3, PA-25).
3. A user action aimed at a row calls `scrollRowToVisible` and nothing more. These actions are ⌘1 to ⌘9, ⇧⌘[ and ⇧⌘], ⌃⌘↑ and ⌃⌘↓, ⌘J, the palette, a notification click and a new tab. New tabs append to the end of their workspace.
4. Deleting a workspace keeps the scroll offset (REQUIREMENTS §8.4, PA-24) and moves the keyboard highlight to the row that took its place: the next row, or the previous one at the end. If the deleted workspace was active, that row's workspace becomes active.
5. After a reorder by drag or Move Up and Move Down, the moved row keeps focus and scrolls into view. Removing a tab or workspace row moves the keyboard highlight to the next row, or the previous one at the end, without scrolling (PA-26).

### 3.8 Accessibility and semantic snapshot

| Element | Identifier | VoiceOver label; the AX value is the raw state |
|---|---|---|
| Workspace row | `rail.workspace:<workspaceName>` | "{name}", then ", branch {branch}" when known, then ", 1 needs you", ", 2 need you" or ", {state word}" in lowercase. Examples: "Obsess, branch rate-limit, 1 needs you" and "Site, done". |
| Tab row | `rail.tab:<workspaceName>/<tabName>` | "{display name}, {phrase}" with one of "needs you", "failed, exit 1", "couldn't start, folder missing", "working", "running", "serving on port 4000", "done", "starting", "stopping", "stopped". Idle adds nothing. `accessibilityHelp` is "Agent tab" or "Shell tab". |

Identifiers go on the row views, and `<tabName>` is always the stable name, never the title. `ui.snapshot.model.rail` lists the rows in display order, so drives can check rendering without pixels. Workspace rows appear as `{kind:"workspace", id, name, expanded, branch?, state, accessory}` and tab rows as `{kind:"tab", id, workspaceId, name, display, icon:"agent"|"shell"|"server", state, accessory, selected, hint?}`. `accessory` is one of `"badge:<n>"`, `"word:<text>"`, `"port:<label>"`, `"dot:running"`, `"dot:done"`, `"dot:failed"`, `"dot:muted"`, `"ring:stopped"` or `null`.

## 4. Panes and tiling

Tasks T1.2 and T4.1. The daemon owns the layout tree (`layout.*`, `pane.*`), and an AppKit container renders it.

### 4.1 Pane card and header

A pane (`pane:<paneId>`) is a card filled with `pane`, radius 12, with a 1 pt `paneHairline` border and clipped content. Its header is 36 tall, with padding 0 12 (0 8 0 12 when it ends in buttons), gap 8 and a 1 pt `paneDivider` rule below. Terminal bodies use libghostty with `window-padding-x = 14`, `window-padding-y = 12` and `window-padding-color = background`. The focused pane gets a 1.5 pt `accent` ring outside its edge and the shadow `0 10 30 rgba(0,0,0,0.25)`. While the window is not key, the ring drops to 35% alpha. A workspace with a single pane shows no ring. Clicking anywhere in a pane focuses it.

Header contents, left to right: the kind icon at 14 (`icon`, or `#C3CBDB` when focused), the title in 13 semibold `text.primary`, then the state. Meta and actions sit at the right.

| Content | State | Meta, then actions |
|---|---|---|
| Agent tab | "Needs you" pill: 11 bold `#1D1F25` on `needs.fill`, radius 9, padding 2 8. "Working" in 12 `running`. "Done" in 12 `done`. "Failed" in 12 `failed` with "exit N" in `text.secondary`. Nothing when idle. | `arrow.triangle.branch` 12 and "backend · rate-limit" (cwd basename and branch) in 12 `text.secondary`, with the full `~` path as tooltip. Stop while working. |
| Shell tab | "Running" in 12 `running` while a command runs, after 500 ms. Done and Failed as for agents. | Same meta. Stop while a command runs. |
| Serving shell | A 6 pt `done` dot and "Running" in 12 `text.secondary`. | The URL button "localhost:4000" (`pane.openURL:<tabName>`) in 12 `accent`, 24 tall, padding 0 6, tooltip "Open in Browser". It becomes a pull-down with one item per port when there are several. The folder and branch move into the tooltip. Then Stop. |
| Failed | "Failed" in 12 `failed` and "exit 1" in 12 `text.secondary`. The card border turns `failed.border` unless the pane is focused. | Meta only. v1 has no Restart, because managed servers are LATER. |
| Couldn't start | "Couldn't start" in 12 `failed`, border `failed.border`. | A short reason in `text.secondary`: "Folder missing", "Command not found", or "Launch failed" for anything else. Then a primary [Retry] (`pane.retry:<tabName>`), which relaunches in this same pane and leaves the split tree alone (PA-19). |
| File | "+18" in `done` and "−4" in `failed`, both 12, only for a changed file in a repository. | The folder relative to the repository root or `~`, in 12 `text.secondary` with head truncation. Then [Diff] (`pane.showDiff:<absPath>`), then Close with the dirty dot (§6.1). |
| Diff | The same counts, plus "vs HEAD" in 12 `text.secondary`. | The relative folder, [Open File] (`pane.openFile:<absPath>`, disabled for deleted files), Close. |

Text buttons are 24 tall with padding 0 9, radius 6, and 12 `text.body` on `control`. Primary buttons are `button.primary` with 12 semibold white text. Icon buttons are 24×24, radius 6, with a 14 glyph in `icon`. While a button's action is in flight it is disabled at 50% opacity and ignores clicks, and Retry reads "Retrying…" (PA-25).

Stop (`pane.stop:<tabName>`) is a text button with the `stop` glyph at 12. On a working agent it calls `tab.interrupt`, with the tooltip "Interrupt Agent (⇧⌘X)" (R-AG-4). On a command or a server it calls `tab.stop`, with the tooltip "Stop Command (⌘.)" (R-SRV-4). It always acts on its own pane's tab, never on the focused one (REQUIREMENTS §8.7). Close (`pane.close:<paneId>`, tooltip "Close Pane (⌘W)") always shows on file and diff panes. On terminal panes it fades in over 120 ms while the pointer is over the header, and it stays in the AX tree. Headers are `pane.header:<tabName>`, or `pane.header:<absPath>` for files and diffs. Bodies are `pane.terminal:<tabName>`, `pane.file:<absPath>` and `pane.diff:<absPath>`.

### 4.2 Split, close, resize, focus

| Action | Behavior |
|---|---|
| ⌘D, ⇧⌘D | Split the focused pane right or down. The new pane gets a new shell in the focused tab's cwd, or in the file's folder when a file or diff pane is focused. It takes half of the focused pane and gets focus. A split along the parent's axis adds a sibling instead of nesting. A split that would leave a pane under 200×120 calls `NSSound.beep()` and does nothing. |
| ⌘W | `pane.close`. The tab keeps running in the background. Focus goes to the neighbor that takes the space: the next sibling, else the previous one. The last pane becomes an empty pane. A dirty file pane asks first, in a sheet: `Save changes to "session.ts"?` / "Your changes are lost if you don't save them." / [Save] [Don't Save] (`dialog.discard`) [Cancel]. |
| ⇧⌘W | Close Tab, with the R-TAB-7 confirmation. The tab's pane closes too, or turns empty when it is the only pane. |
| Drag a gutter | The 8 pt gutters are the divider hit areas, and hovering one only changes the cursor. Resizing is live, and `pane.resize` runs on mouse-up. A double-click equalizes that split. Pane > Equalize Panes calls `pane.equalize`. |
| ⌥⌘ and an arrow | Focuses the nearest pane in that direction. Nothing happens at an edge. |
| Select a background tab | The tab replaces the focused pane's content (R-LAY-3). A focused file or diff pane is never replaced: the tab goes to the most recently focused terminal pane, or to a new split on the right when there is none. Hidden surfaces detach after 30 s (ARCHITECTURE §4.3). |

Pane geometry never animates. A terminal should reflow once, not on every frame.

### 4.3 Connection problems and notices

| Case | UI |
|---|---|
| `mapo attach` gives up after 30 s of retries (ARCHITECTURE §3.4) | The terminal body gets a `pane` scrim at 80%, centered on it "Disconnected" in 13 semibold `text.primary`, then "This terminal lost its connection to mapod. The tab keeps running while mapod is up." in 12 `text.secondary`, and a primary [Reconnect] (`pane.reconnect:<tabName>`). Reconnect builds a new surface, which replays. While mapod is unreachable the button is disabled and reads "Waiting for mapod…". |
| The shell exited non-zero or on a signal (EXIT frame, `stopped`, R-TAB-12); exit 0 closes the tab instead | A bar at the bottom of the body: "The shell exited with code {n}." or "The shell was stopped by {signal}.", with [Restart] and [Close Tab]. Restart relaunches the tab from its definition in the same pane. |
| An expected failure from a UI action (PA-27), such as a rejected `file.open`, a stale process identity or a bad `config.toml` (PA-43) | `app.notice`: a bar 32 tall and up to 480 wide at the bottom center of the panes area, `overlay` material, 12 `text.body`, with an optional action (`app.notice.action`) and a close button. It shows the daemon's message, stays 8 s (longer while the pointer is over it), never takes focus, and VoiceOver announces it. A newer notice replaces it. Example: "config.toml line 12: expected a string. Mapo keeps the last good settings." with [Open config.toml]. |
| The control connection is down | `app.banner`, a 32 pt `overlay` bar at the top of the panes area, reads "Reconnecting to mapod…". After 10 s it reads "Can't reach mapod. Mapo keeps retrying." and offers [Restart mapod] (`app.banner.action`). |
| Protocol mismatch (PROTOCOL §2) | The banner reads "mapod is from another build (protocol {d}, app {a}). Restart it to continue. Shell commands stop; agents resume." with [Restart mapod]. |

### 4.4 Drops and the empty pane

Dragging files from Files, Changes or Finder over a terminal pane shows the `accent` ring on that pane. The drop types each absolute path single-quoted, with `'` escaped as `'\''`, separated by spaces, with a trailing space and no Return (R-FS-4).

An empty pane has no header. Centered in it: "Empty pane" in 13 semibold `text.secondary`; a primary [New Shell Tab] followed by "⌘T" (`pane.empty.newShell:<paneId>`); a text button [New Agent Tab] followed by "⇧⌘T" (`pane.empty.newAgent:<paneId>`); and "Or choose a tab in the sidebar." in 12 `text.secondary`. Return triggers New Shell Tab, and ⌘T or ⇧⌘T open their tab in this pane.

## 5. Inspector

Tasks T1.5 and T4.3. The inspector (`inspector`) follows the cwd of the last focused tab, never the file pane (R-FS-2), and it re-roots without taking focus. When the workspace has no tabs left, it shows the no-terminal states (PA-22).

### 5.1 Segments

The segment control is a custom capsule: 30 tall, padding 2, radius 15, `control` fill, a 1 pt `hairline`, and the inspector's width minus 24. The selected segment has radius 13, fill `rgba(255,255,255,0.14)` (light `rgba(0,0,0,0.07)`) and 13 semibold `text.primary`. The other segment uses 13 regular `#C3C7D0` (light `text.secondary`). "Changes" carries a count badge when `totals.files` is above zero: 11 bold `#1D1F25` on `#A3A8B3` (light: white on `text.secondary`), radius 8, padding 0 6. The UserDefaults key `inspector.segment.<instance>` remembers the last segment. The palette commands "Show Files" and "Show Changes" also open a hidden inspector.

### 5.2 Files

- **Header** (`inspector.files.header`). Padding 2 16 10, gap 8. It shows `folder` 14 in `icon`, then the cwd as a `~` path in 12 `text.body`, truncated at the head so the end stays visible, with the full path as tooltip. Last comes a branch chip: `arrow.triangle.branch` 11 and the branch in 11 `#C3C7D0` (light `text.secondary`) on `control`, radius 6, padding 2 6. Outside a repository there is no chip. Right-click offers Copy Path · Reveal in Finder.
- **Tree.** An `NSOutlineView` that loads children through `fs.list` as folders expand. List inset 0 8. Rows (`inspector.files.row:<relPath>`, relative to the Files root) are 26 tall, radius 6, gap 6. Folders show a chevron 12, `folder` 14 and the name. Files show `doc` 14, aligned with their sibling folders' icons, and the name. The leading inset is `8 + 18 × depth`, plus 18 for files. Names use 13 `text.body`, and rows with `ignored: true` use `text.disabled`. Folders sort first (R-FS-3).
- **Selection and keys.** The row of the file in the focused file pane gets `rowCurrent`, and keyboard selection uses `selection`. Clicking a folder toggles it. Clicking a file opens it with `file.open` and focuses the editor (REQUIREMENTS §8.3). Arrows move without opening, → and ← expand and collapse, Return opens, and type-to-select works.
- **Context menus** (R-FS-4). Files: Open · Open With Default App | Reveal in Finder | Copy Path · Copy Relative Path. Folders: New Shell Tab Here | Reveal in Finder | Copy Path · Copy Relative Path. Dragging rows onto a terminal inserts their paths (§4.4).
- **Updates.** `fs.changed` refreshes the affected folders in place, keeping expansion and scroll. A newer refresh supersedes an older one, and the last focused tab wins (REQUIREMENTS §8.9). Expansion is remembered per root for the session.
- **Footer** (`inspector.files.footer`). Shown when the repository has changes: padding 12 16, a 1 pt `paneDivider` rule above, 12 `text.secondary` reading "3 changed files", then "+87" in `done` and "−6" in `failed`. Clicking it shows Changes.

Git status tints the name and adds a trailing letter in 11 bold, same color:

| `fs.list` git value | Letter | Color |
|---|---|---|
| `M` | M | `needs` |
| `A`, `R` | A, R | `done` |
| `?` (untracked) | U | `done` |
| `U` (conflicted) | C | `failed` |
| Collapsed folder with changes | 6 pt dot | Worst child: C, then M, then A or U |

States (R-FS-5) are centered, with the title in 13 semibold `text.secondary` and the body in 12 `text.secondary`. The state name is the AX value of `inspector.files.state`.

| State | Copy | Action |
|---|---|---|
| `loading`, after 300 ms | A small spinner and "Loading…". A listing still unfinished after 4 s is retried (PA-32). | |
| `empty` | "Empty folder" / "~/code/obsess/tmp has no files." When exclude rules hide everything: "Nothing to show" / "Exclude rules hide every item in ~/code/obsess/tmp." (PA-32) | |
| `missing` | "Folder not found" / "~/code/legacy-api was moved or deleted. Restore it and retry, or cd somewhere else." The tree also recovers by itself when the folder comes back (PA-32). | [Retry] (`inspector.files.retry`) |
| `unreadable` | "Can't read this folder" / "Check the permissions of ~/private in Finder, then retry." | [Retry] |
| `no-terminal` | "No terminal focused" / "Focus a terminal to see its folder here." | |

### 5.3 Changes

- **Summary** (`inspector.changes.summary`). 36 tall, padding 0 16, 12 pt text, gap 6. It shows `arrow.triangle.branch` 12, the branch in `text.body`, then the upstream as "↑2 ↓1" in `text.secondary`. A zero side is left out, "no upstream" appears when there is none, and a detached HEAD reads "detached at a7bc6c9". At the right edge: "3 files" in `text.secondary`, "+87" in `done`, "−6" in `failed`. Tooltip: "Upstream origin/rate-limit: 2 ahead, 1 behind".
- **Size warning** (`inspector.changes.warning`, R-GIT-1). When `git.status` returns `warn`, a row under the summary shows `exclamationmark.triangle` 12 in `needs` and the string verbatim in 12 `text.body`. The daemon writes it as "Large change: 1,812 lines in 64 files. Consider splitting it."
- **Rows** (`inspector.changes.row:<relPath>`). 26 tall, radius 6, list inset 0 8. One flat list against HEAD, sorted by path, with staged, unstaged and untracked files together. Each row shows the status letter in 11 bold, 12 wide (letters and colors as in §5.2, plus `D` in `failed`), gap 6, the file name in 13 `text.body`, gap 6, the folder in 12 `text.secondary` with head truncation, then "+N" in `done` and "−N" in `failed` in 12 monospaced digits. A zero count is left out, and binary files show "bin" in `text.secondary`.
- **Selection.** Clicking a row, or arrowing onto it, shows its diff in the workspace's file pane. The pane switches to `Diff(root, path)`, or appears as R-LAY-5 describes. Keyboard focus stays in the list, so ↑ and ↓ step through diffs, debounced 100 ms. Return or a double-click opens the file in the editor and focuses it. Context menu: Open File · Show Diff | Reveal in Finder | Copy Path · Copy Relative Path. `git.changed` refreshes the list in place (R-GIT-3) and keeps the selection while its path still exists.

States (`inspector.changes.state`):

| State | Copy | Action |
|---|---|---|
| loading, after 300 ms | "Loading changes…" | |
| not a repository | "Not a git repository" / "~/Downloads isn't inside a git repository." | |
| clean | "No changes" / "The working tree matches HEAD." | |
| error | "Couldn't read git status" / "{first line of git's stderr}. Fix it in a terminal, then retry." | [Retry] (`inspector.changes.retry`) |
| no terminal | "No terminal focused" / "Focus a terminal to see its repository's changes." | |

## 6. File pane and editor

Task T1.6; T4.3 adds the gutter's base text. A workspace has at most one file pane (R-LAY-5). Opening a file when there is none splits right of the focused terminal, or fills a focused empty pane. Opening a file always focuses the editor.

### 6.1 Chrome and editor

- **Recent files.** The header title is followed by `chevron.down` 9. It opens a pull-down (`pane.recent:<paneId>`) of up to 10 files, newest first, each as "session.ts · backend/src/auth", with a checkmark on the current file and "Clear Recent Files" at the end. Picking a file swaps the content in place and never adds a pane. The list persists per workspace.
- **Dirty indicator** (R-ED-1). While the buffer is dirty, the Close button shows a 6 pt `text.body` dot that turns into `xmark` on hover, and the AX label becomes "session.ts, edited". `NSWindow.isDocumentEdited` is true, so the red traffic light shows its dot too.
- **Text view** (`editor:<absPath>`). An `NSTextView` on TextKit 2 in SF Mono 12.5 with a 20 pt line height. Insets are 10 at the top and bottom and 8 after the gutter, with overlay scrollers. The caret is `text.body`. The selection is `editor.selection`, at 60% while inactive. The current line is `editor.currentLine`, only while focused with nothing selected. Soft wrap starts off and line numbers on; View > Soft Wrap and View > Line Numbers toggle them per pane. Tab inserts the file's detected indent, 4 spaces by default.
- **Gutter.** A 3 pt hunk bar (radius 2) at x = 0, then line numbers right-aligned 14 pt before the text, in SF Mono 12.5 `lineNumber`; the current line's number is `text.body`. The width is `3 + max(34, digits × advance + 14)`. Bars (R-ED-3) show added lines in `done`, modified lines in `running`, and deletions as a 3×6 `failed` wedge centered on the line boundary. The app diffs against `git.baseText` 200 ms after typing stops and on save. Clicking a bar shows that hunk inline in diff colors (R-ED-7, SHOULD); the canvas's faint added-line tint `rgba(111,207,151,0.07)` is used only there.
- **Find.** The `NSTextFinder` find bar, with `usesFindBar = true`, incremental search and `findBarPosition = .aboveContent`. ⌘F finds, ⌥⌘F adds replace, ⌘G and ⇧⌘G step, and Esc closes it and returns focus to the text. macOS supplies its copy. ⌘L opens the palette in line mode (§10), where "42" or "42:7" jumps there and centers the line.
- **Previews** (R-FS-6). Raster images sit centered and fitted, never above 100%, over an 8 pt checkerboard of `rgba(255,255,255,0.04)` (light `rgba(0,0,0,0.04)`). The header meta reads "1280 × 800 · 214 KB". While a preview has focus, ⌘+ and ⌘− zoom it, ⌘0 fits it, and pinch zooms. PDFs use PDFKit `PDFView`, continuous and auto-scaled, with "12 pages" as the meta. Markdown files get a [Preview] toggle (`pane.preview:<absPath>`, SHOULD).
- **Big and binary files** (R-ED-6). A file over 8 MB opens read-only, with the bar "This file is over 8 MB, so it opened read-only." and [Open With Default App] (`editor.openDefault:<absPath>`). A binary file shows "session.db is a binary file." with [Open With Default App] and [Reveal in Finder] (`editor.reveal:<absPath>`).

### 6.2 Bars and prompts

Bars sit at the top of the editor body: 32 tall, padding 0 12, `control` fill, 12 `text.body`, buttons at the right.

| Trigger | Copy | Buttons |
|---|---|---|
| The file changed on disk while the buffer is dirty (R-ED-4). A clean buffer reloads silently. | "session.ts changed on disk. Keep your edits, or reload and lose them?" | [Keep Mine] (`editor.keepMine:<absPath>`, default) and [Reload] (`editor.reload:<absPath>`). Keep Mine keeps the buffer, and the next save overwrites the file. |
| The file was deleted on disk | "session.ts was deleted on disk. Save to recreate it, or close the pane." | [Close] (`editor.close:<absPath>`) |
| A recovery copy is newer than the file (R-ED-5) | "Recovered unsaved edits to session.ts from a previous session." | [Restore] (`editor.restore:<absPath>`) and [Discard] (`editor.discard:<absPath>`) |
| Saving failed (PA-27) | "Couldn't save session.ts. You don't have permission to write to it; check its permissions in Finder, then try again." The text stays dirty. | [Try Again] (`editor.retrySave:<absPath>`) and [Reveal in Finder] (`editor.reveal:<absPath>`) |

Quitting with dirty files asks in a sheet: "Save changes to 2 files before quitting?" / "Your changes are lost if you don't save them." / [Save All] [Don't Save] [Cancel]. When `file.open` rejects a folder, missing path, broken link or unreadable file (REQUIREMENTS §8.10), an `app.notice` shows the daemon's message and the layout stays as it was.

### 6.3 Unified diff view

A read-only `NSTextView` in SF Mono 12.5 with a 20 pt line height shows `git.diff` from the first `@@`. It drops the `diff --git`, `index`, `---` and `+++` lines, and v1 has no syntax colors in diffs. Line backgrounds span the full width: hunk headers use `diff.hunk` on `diff.hunkBg`, added lines `diff.addedText` on `diff.addedBg`, removed lines `diff.removedText` on `diff.removedBg`, and context `#C3C7D0` (light `text.body`). The gutter has old and new line numbers in two right-aligned `lineNumber` columns, each at least 34 wide with 10 padding. The `+` or `-` prefix stays in the text. A binary diff shows "Binary files differ." and [Open With Default App].

## 7. Status and attention

Tasks T1.4 and T2.4. The daemon computes `state`, `stateLabel`, `stateDetail` and `WorkspaceSummary.summary` in `mapo-core::status`, and the app shows them as they arrive. Priority order: needs-you, failed, running, done, starting, stopping, idle, stopped (R-ST-1).

### 7.1 Vocabulary

| State | Word | Color | Rail | Pane header | Notifies |
|---|---|---|---|---|---|
| `needs-you` | Needs you | `needs`, name `needs.tint` | Word; workspace badge | Filled pill | When not visible |
| `failed` | Failed, with "exit N" where it fits | `failed`, name `failed.tint` | Word; red dot on a collapsed workspace | Word, exit code, red border | When not visible |
| `failed` with a launch error | Couldn't start | `failed` | Word | Word, reason, Retry | When not visible |
| `running`, agent | Working | `running` | Dot | Word, Stop | No |
| `running`, command | Running | `running` | Dot, after 500 ms | Word after 500 ms, Stop | No |
| `running`, serving | Running | `done` dot | Server icon and ":4000"; never the workspace's state or summary (R-WS-7) | Dot, word, URL, Stop | No |
| `done` | Done | `done` | Dot | Word | When not visible |
| `starting`, `stopping` | Starting, Stopping | `text.secondary` | Muted dot, after 500 ms | Word | No |
| `idle` | none | | Nothing | Nothing | No |
| `stopped` | Stopped | `stopped` | Ring | Word and the exit bar (§4.3) | No |

`stateDetail` for needs-you is "Asking for permission" (PermissionRequest or permission_prompt), "Asking a question" (elicitation dialogs), "Waiting for input" (agent_needs_input), "Stopped on an error" (StopFailure), "Waiting for folder trust" and "Waiting for login" when those dialogs are found on screen, or "Rang the bell" for a BEL from a shell tab without hooks (PA-9, SHOULD). For failed it is "exit N", and for Couldn't start it is `launchError.message`.

### 7.2 Workspace summaries

`n` counts only the tabs in the most urgent state, and serving tabs never count (R-WS-7).

| Most urgent | One tab | Several |
|---|---|---|
| needs-you | "be-claude needs you" | "2 need you" |
| failed | "web failed" | "2 failed" |
| running | "fe-claude is working" for an agent, "api is running" for a command | "3 working" if any is an agent, else "3 running" |
| done | "site-claude is done" | "2 done" |

Any other state gives an empty summary. Summaries appear in workspace row tooltips and VoiceOver labels, in palette workspace rows and in `mapo workspace list`.

### 7.3 Notifications and dock badge (R-ST-3, R-ST-4)

Mapo posts a notification only when you cannot see the tab: Mapo is inactive, the window is minimized or occluded, the tab is in another workspace, or it is in no visible pane. `[attention] notify` picks which states notify. The notification identifier is the tab id, so a newer state replaces the older notification, and `removeDeliveredNotifications` withdraws it once the attention clears. Clicking a notification activates Mapo and calls `tab.focus`. Needs-you and failed use the default sound; done is silent. Notifications are not in the AX tree; posting or suppressing one writes the `notification:<tabId>` log line of ENGINEERING §4.2.

| State | Title | Body |
|---|---|---|
| needs-you | "be-claude needs you" | "Obsess · Asking for permission" ({workspace} · {stateDetail}) |
| failed | "web failed" | "Infra · exit 1" |
| Couldn't start | "legacy-api couldn't start" | "Obsess · {launchError.message}" |
| done | "site-claude is done" | "Site · finished in 4 min" |

Durations read "38 s", "4 min" or "1 h 12 min". They run from entering `running` to `done`, using `tab.state` event times, or `lastExit.durationMs` for commands. Notifications never include terminal text, so the canvas's "Approve pnpm db:migrate" and error-line examples are not in v1.

The dock badge, `NSApp.dockTile.badgeLabel`, counts tabs in `needs-you` across all workspaces, computed from tab states. Do not use `attention.changed.count`, because it also counts failed and unviewed done tabs. The label is empty at zero and "99+" above 99. It updates at once, even while Mapo is active. There is no bouncing and no `requestUserAttention`.

### 7.4 Clearing

| State | Clears when |
|---|---|
| done | Its pane is focused in the key window with its workspace active, as reported through `ui.visibility`. Merely visible is not enough. |
| failed | The next command starts in the tab (OSC 133;C). |
| needs-you | The agent's own hook events (UserPromptSubmit, PostToolBatch, Stop) or an interrupt. Viewing or focusing never clears it (R-ST-5, PA-1). A bell-based needs-you on a shell tab clears when the tab is focused or its command finishes (PA-9). |
| Couldn't start | A retry succeeds. Focusing the tab retries, one attempt at a time (R-TAB-9). |

⌘J (R-ST-6) focuses the next attention tab after the focused one, wrapping around. The order is needs-you, then failed, then unviewed done, each in rail order. With no attention tabs the menu item is disabled.

## 8. Keyboard map and menu bar

Task T1.8. One keymap table builds both the menu bar and the palette's Commands section (R-KEY-2). Menu key equivalents win over the terminal and work whichever pane has focus, previews included (PA-29). ⌘C, ⌘V and ⌘A go to the first responder, the terminal included. ⌘K takes over Ghostty's clear-screen binding.

| Menu | Item | Shortcut | Notes |
|---|---|---|---|
| Mapo | Settings…, Quit Mapo | ⌘,, ⌘Q | Settings opens `config.toml` in the file pane (D-30). Quit asks about unsaved files (§6.2). |
| File | New Workspace | ⇧⌘N | `workspace.create`, then one shell tab in the home folder, focused (PA-23). The CLI creates it empty. |
| | New Shell Tab | ⌘T | In the focused tab's folder, else home (R-TAB-2). With no workspace, creates "Workspace N" first (PA-23). |
| | New Agent Tab | ⇧⌘T | Runs the workspace agent command, in the same folder as ⌘T. |
| | New Tab in Folder… | ⌥⌘T | The §3.5 sheet. |
| | Save | ⌘S | A file pane is focused. |
| Edit | Find | ⌘F | A file or diff pane is focused. |
| | Find and Replace, Go to Line… | ⌥⌘F, ⌘L | A file pane is focused. |
| View | Hide Sidebar / Show Sidebar | ⌃⌘S | System `toggleSidebar:`, the brief's "Toggle Rail". |
| | Hide Inspector / Show Inspector; Show Files, Show Changes | ⌥⌘0 for the toggle | System `toggleInspector:`. Show Files and Show Changes also open a hidden inspector. |
| | Go to Tab, File or Command… | ⌘K | Toggles the palette. |
| | Bigger, Smaller, Actual Size | ⌘+ (also ⌘=), ⌘−, ⌘0 | All terminals and editors, 1 pt steps from 9 to 24, not saved. ⌘0 returns to `[terminal] font-size`. A focused image or PDF preview zooms instead (§6.1). |
| | Soft Wrap, Line Numbers | | Checkmark items for the focused editor. |
| Workspace | Previous Workspace, Next Workspace | ⌃⌘↑, ⌃⌘↓ | Rail order, no wrap. |
| | Rename Workspace, Set Agent Command…, Move Workspace Up, Move Workspace Down | | §3.4 and §3.5; the moves call `workspace.move`. |
| | Delete Workspace | | With the §3.5 confirmation. |
| Tab | Next Tab That Needs You | ⌘J | SHOULD. Enabled while any tab has attention. |
| | Previous Tab, Next Tab | ⇧⌘[, ⇧⌘] | Rail order within the workspace, wrapping. |
| | Go to Tab > 1 to 9 | ⌘1 to ⌘9 | Items titled like "1  be-claude", enabled when tab N exists. Hints show while ⌘ is held (§3.3). |
| | Rename Tab | ⌥⌘R | Inline rename in the rail, which opens if hidden. |
| | Interrupt Agent | ⇧⌘X | The focused tab is a working agent. Sends Esc. |
| | Stop Command | ⌘. | The focused tab runs a command. Sends Ctrl-C. |
| | Close Tab | ⇧⌘W | With the R-TAB-7 confirmation. |
| Pane | Split Right, Split Down | ⌘D, ⇧⌘D | |
| | Focus Pane Left, Right, Up, Down | ⌥⌘←, ⌥⌘→, ⌥⌘↑, ⌥⌘↓ | A pane exists in that direction. |
| | Equalize Panes, Close Pane | ⌘W for Close Pane | Equalize calls `pane.equalize`. |
| Window | Minimize, Zoom, Bring All to Front | ⌘M | Standard. |

The standard items keep their macOS places and shortcuts: About Mapo, Hide Mapo (⌘H), Hide Others (⌥⌘H) and Show All in the Mapo menu; Undo (⌘Z), Redo (⇧⌘Z), Cut, Copy, Paste, Select All, Find Next (⌘G) and Find Previous (⇧⌘G) in Edit; Enter Full Screen (⌃⌘F) in View. v1 has no Help menu. The palette lists every Mapo-specific item above.

## 9. Appearance tokens

Task T1.9. Tokens live in `MapoUI/Theme/Tokens.swift` as `Theme` (also spelled `Tokens`): `NSColor(name:dynamicProvider:)` colors resolving `.darkAqua`, `.aqua` and both `.accessibilityHighContrast*` appearances, plus `Theme.Radius`, `Theme.Spacing`, `Theme.focusRingWidth` and `Theme.Motion`. The app follows the system appearance, and `[ui] theme = "mapo-glass"` selects this palette. `[ui] appearance = "system" | "dark" | "light"` and `reduce-transparency = "system" | "on" | "off"` override the system for this instance, so drives can capture every variant; they are read at launch (`Theme.apply`, `MapoUI/Theme/Appearance.swift`), and `ui.window` reports the result as `appearance`, `reduceTransparency` and `increaseContrast`.

### 9.1 Colors

Dark is the canvas palette from the brief. Light is derived here.

| Token | Dark | Light | Use |
|---|---|---|---|
| `backdrop` | Gradient `#25272E` to `#1F2127`; glows `rgba(125,166,255,0.13)` top left and `rgba(172,140,255,0.09)` bottom right | Gradient `#F4F5F8` to `#E9EBEF`; glows `rgba(47,107,224,0.08)` and `rgba(124,77,219,0.06)` | Window background |
| `glass` | `rgba(43,46,54,0.62)`, blur 28, saturate 160% | `rgba(255,255,255,0.62)`, blur 28, saturate 160% | Reference look of the rail and inspector; custom glass |
| `hairline`, `highlight` | `rgba(255,255,255,0.08)`; inset top `rgba(255,255,255,0.06)` | `rgba(0,0,0,0.08)`; `rgba(255,255,255,0.70)` | Glass edges |
| `pane`, `paneHairline`, `paneDivider` | `#1D1F25`, `rgba(255,255,255,0.07)`, `rgba(255,255,255,0.06)` | `#FFFFFF`, `rgba(0,0,0,0.08)`, `rgba(0,0,0,0.06)` | Pane cards and the terminal and editor background; pane border; header rule |
| `overlay` | `rgba(44,47,55,0.80)`, blur 30, saturate 170% | `rgba(250,250,252,0.82)`, blur 30, saturate 170% | Palette, banner, notice |
| `hover`, `pressed`, `control`, `rowCurrent` | White at 0.05, 0.08, 0.07, 0.08 | Black at 0.04, 0.07, 0.05, 0.06 | Row and button fills |
| `selection` | `rgba(138,176,255,0.16)` | `rgba(47,107,224,0.14)` | Selected rows in the rail, tree and palette |
| `text.primary`, `text.body` | `#F2F3F6`, `#D5D8DF` | `#16181D`, `#2B2E36` | Titles, body |
| `text.secondary`, `text.secondaryOnSelection`, `text.disabled` | `#9EA3AE`, `#C3C7D0`, `#6E7380` | `#5E6470`, `#5E6470`, `#8A8F99` | Metadata; disabled and ignored rows |
| `icon`, `icon.selected`, `lineNumber` | `#A3A8B3`, `#DCE3F2`, `#858A98` | `#636977`, `#16181D`, `#6F7582` | Glyphs, gutters |
| `accent`, `button.primary` | `#8AB0FF`; `#4A70D6` with white text | `#2F6BE0`; `#2F63D0` with white text | 1.5 pt focus ring, links, match highlights; primary buttons |
| `needs`, `needs.tint`, `needs.fill` | `#E8B557`, `#F1CB86`, `#E8B557` | `#8F5B00`, `#6E4600`, `#E8B557` | Needs you |
| `failed`, `failed.tint`, `failed.border` | `#F47067`, `#F6C9C5`, `rgba(244,112,103,0.35)` | `#B42F28`, `#9A221B`, `rgba(180,47,40,0.35)` | Failed |
| `running`, `done`, `stopped` | `#6CA8FF`, `#6FCF97`, `#858A98` | `#2563C9`, `#177040`, `#8A8F99` | Dots, words, gutter bars; `done` is also the serving dot |
| `diff.addedBg`, `diff.addedText`, `diff.removedBg`, `diff.removedText` | `rgba(111,207,151,0.14)`, `#CFEFD9`, `rgba(244,112,103,0.14)`, `#F6C9C5` | `rgba(34,160,90,0.14)`, `#13522E`, `rgba(214,64,55,0.12)`, `#8C1D17` | Diff lines |
| `diff.hunk`, `diff.hunkBg` | `#9EA3AE`, `rgba(255,255,255,0.03)` | `#5E6470`, `rgba(0,0,0,0.03)` | Hunk headers |
| `editor.selection`, `editor.currentLine` | `rgba(125,166,255,0.25)`, `rgba(255,255,255,0.03)` | `rgba(47,107,224,0.20)`, `rgba(0,0,0,0.03)` | Editor |
| Syntax keyword, string, function, type, number, punctuation, comment | `#C3A6FF`, `#A6D98C`, `#8AB0FF`, `#7FD1C7`, `#E8B557`, `#A3A8B3`, `#7E8391` | `#7A3FD1`, `#3B7A1A`, `#2456C8`, `#0B7468`, `#8F5B00`, `#5E6470`, `#6A7080` | Tree-sitter captures |
| Dock badge | `#D92D24` | `#D92D24` | macOS draws it |

The terminal theme is libghostty config, switched live with the appearance. ANSI colors are normal / bright:

| Mode | Base | Black | Red | Green | Yellow | Blue | Magenta | Cyan | White |
|---|---|---|---|---|---|---|---|---|---|
| Dark | bg `#1D1F25`, fg and cursor `#D5D8DF`, selection-background `#35415C` | `#2B2E36` / `#6E7380` | `#F47067` / `#F89A92` | `#6FCF97` / `#9BE0B6` | `#E8B557` / `#F1CB86` | `#6CA8FF` / `#A6C3FF` | `#C3A6FF` / `#D8C5FF` | `#7FD1C7` / `#A8E3DC` | `#D5D8DF` / `#F2F3F6` |
| Light | bg `#FFFFFF`, fg and cursor `#2B2E36`, selection-background `#D5E1F9` | `#2B2E36` / `#5E6470` | `#B42F28` / `#D0453D` | `#177040` / `#1F8F52` | `#8F5B00` / `#A86E00` | `#2563C9` / `#2F6BE0` | `#7A3FD1` / `#9160E0` | `#0B7468` / `#13897B` | `#C9CCD3` / `#9A9FAA` |

Contrast, as WCAG ratios against composited backgrounds:
- **Light.** Every text token passes 4.5:1 on the pane `#FFFFFF`, on glass (about `#FAFAFC`) and on a selected row (about `#DEE6F8`). The tightest pairs are all on a selected row: `running` 4.5, `needs` 4.6, `text.secondary` 4.8, `done` 4.9. `lineNumber` measures 4.6 on the pane, its only background. White on `button.primary` is 5.5. Disabled text is exempt.
- **Dark.** On the pane and on glass, every text token passes except comments: `text.secondary` 6.5 and 5.6, `failed` 5.8 and 4.9, `lineNumber` 4.8, white on `button.primary` 4.6. On a selected row (about `#384154`), `text.secondary` drops to 4.1 and `failed` to 3.6, which is why selected rows switch to `text.secondaryOnSelection` (6.1) and `failed.tint` (6.9). Comments (`#7E8391`) measure 4.35 on the pane; they keep the canvas value, and Increase Contrast raises them.
- **Non-text.** Status dots clear 3:1 in both modes. Badge text on `needs.fill` is 8.8:1.

Increase Contrast raises hairlines to 0.24 alpha (light 0.28), renders `text.secondary` as `text.body`, sets comments to `#9EA3AE` (light `#4F5561`), doubles the `selection` alpha and draws a 2 pt focus ring.

### 9.2 Typography, radii and spacing

Chrome text is SF Pro through `NSFont.systemFont(ofSize:weight:)`, and counts use `monospacedDigitSystemFont`. Sizes: 15 semibold for the toolbar title and 15 regular for the palette field. 13 semibold for workspace names, pane header titles and empty-state titles. 13 regular for tree, change and palette rows, segments and body text, with the selected segment in semibold. 12.5 regular for rail tab names. 12 regular for the toolbar subtitle, header meta, buttons (primary buttons semibold), footers, summaries and bars. 11.5 regular for rail accessories and branches. 11 for section headers (semibold), git letters and pills (bold), and hints and chips (regular). 10.5 bold for the workspace badge.

Terminals, the editor and diffs use SF Mono 12.5, the defaults of `[terminal] font-family = "SF Mono"` and `font-size = 12.5`. The editor and diffs use a 20 pt line height. The editor follows the terminal font settings, so the app has one monospaced face.

Radii are 14 for glass panels, the palette and custom glass; 12 for panes; 8 for palette rows; 6 for rail, tree and change rows, header buttons, chips and bars; 4 for the rename field; and 2 for hunk bars. Pills, badges, segments and capsules use half their height, and the system draws window corners. The spacing scale is 2, 4, 6, 8, 10, 12, 16 and 24. Pane gutters and list insets use 8, row padding and the panes area margin 10, header and bar padding 12, and the inspector header 16. The tab row indent of 26 is structural: it puts tab icons 2 pt before workspace names.

### 9.3 Motion

| What | Duration and curve | Under Reduce Motion |
|---|---|---|
| Hover fill, header action reveal, ⌘ hints | 120 ms ease-out in, 80 ms out | Instant |
| Workspace expand and collapse | 160 ms outline animation | Instant |
| Rail and inspector show and hide | System split view animation. Each visible terminal resizes once, when it settles (PA-37) | `isCollapsed` set without the animator |
| Palette open, close | 140 ms fade with scale 0.98 to 1, `cubic-bezier(0.2,0.8,0.2,1)`; close with a 100 ms fade | 100 ms fade to open; instant close |
| Drag-reorder gap | System `.gap` feedback | `.regular` feedback |
| Disconnected overlay, bars, banner, notice | 150 ms fade | Instant |
| Pane geometry, status changes, selection | Never animated | Never animated |

The app reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, `accessibilityDisplayShouldReduceTransparency` and `accessibilityDisplayShouldIncreaseContrast`, and re-applies them on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.

### 9.4 Liquid Glass and Reduce Transparency

| Surface | Material | Under Reduce Transparency |
|---|---|---|
| Rail, inspector | System glass from their split view items | macOS makes it opaque |
| Toolbar items | System glass capsules | macOS makes them opaque |
| Palette, app banner, app notice | `NSGlassEffectView` with cornerRadius 14, or SwiftUI `.glassEffect(in: RoundedRectangle(cornerRadius: 14))`; `overlay` where a custom fill is needed | Opaque `#2C2F37` (light `#FBFBFC`) with `hairline` |
| Any other glass Mapo draws; none is planned in v1 | `glass` | Opaque `#2B2E36` (light `#F7F8FA`) |
| Menus, popovers, alerts, notifications | System | macOS handles it |
| Panes, headers, editor, terminal | Opaque `pane`, never glass | Unchanged |

With `reduce-transparency = "on"` while the system setting is off, macOS keeps the rail and inspector glass, so Mapo lays a `glassOpaque` fill (radius 14) under their content. `"off"` can't undo the system setting for system glass; it only keeps Mapo's own overlays translucent.

## 10. The ⌘K palette

Task T1.7. SwiftUI in a borderless `NSPanel` subclass with `canBecomeKey = true`, attached as a child window of the main window and identified as `palette`. It is 600 wide, clamped between 420 and the panes area width minus 48, and centered over the panes area with its top edge 8 pt below the toolbar band. The height fits the content up to 480. Radius 14, `overlay` material, shadow `0 24 60 rgba(0,0,0,0.38)` (light 0.18).

The field row (`palette.field`) is 44 tall with padding 0 14: `magnifyingglass` 16 in `text.secondary`, text in 15 `text.primary`, the placeholder "Go to tab, file or command", and a `hairline` rule below. The list has padding 6. Section headers are 24 tall, 11 semibold `text.secondary`, padding 0 10. Rows (`palette.row:<index>`, counted from 0 in visible order, headers skipped) are 32 tall, radius 8, padding 0 10, gap 10. A row holds an icon 16, the title in 13 `text.body` with matched characters in semibold `accent`, a truncating subtitle in 12 `text.secondary`, and a trailing item. The selected row takes `selection` and the §3.2 selected-row colors. A row's AX label is "{title}, {section}, {state or shortcut}".

| Section | Icon; title; subtitle; trailing | Return; ⌘Return |
|---|---|---|
| Attention | Kind icon; display name; workspace; state as in the rail | `tab.focus`; Show to the Right |
| Tabs | The same, for tabs in every workspace | The same |
| Workspaces | `square.stack`; name; summary (§7.2) or "5 tabs"; badge | `workspace.activate` |
| Recent files | `doc`; file name; `~` folder with head truncation | `file.open` |
| Commands | `command`; the §8 menu title; shortcut in 12 `text.secondary` | Runs the command. Also offers Refresh Files, Collapse Folders, Show Ports. |
| Ports | `network`; ":4000 · node"; "PID 4123 · api (Obsess)" or "Not in a Mapo tab"; "Protected" when `protected` | Focuses the owning tab. ⌘⌫ closes the palette and asks in a sheet: "Stop node on port 4000?" / "Mapo sends SIGTERM to PID 4123 only." / [Stop Process] [Cancel], then calls `proc.stop`. Disabled when protected. |

- An empty query shows Attention (when any tab has attention), the active workspace's Tabs, up to 5 Recent files, then Workspaces.
- A typed query fuzzy-matches: prefix beats word start beats subsequence, and recency breaks ties. It fills Tabs, Workspaces, Recent files, Commands and Ports in that order, 6 rows each at most. Ports appear when the query is a number or starts with "port".
- A leading ">" limits results to commands. A leading ":" is line mode for the focused editor ("Go to line 42 of session.ts"), and ⌘L opens the palette with ":" already typed.
- ↑ ↓ and ⌃P ⌃N move the selection and wrap. Return runs the row and ⌘Return its alternate. ⌫ in an empty field removes the prefix, and typing always goes to the field.
- Esc, a second ⌘K, a click outside or the window resigning key closes the palette and restores the previous first responder.
- With no matches it shows `No matches for "xyz"` and then "Try a tab, workspace, recent file or command name." in 12 `text.secondary`.

## 11. Copy guidelines

- **Case.** Sentence case for labels, headers, state words, tooltips, messages, notifications and VoiceOver labels. Title Case for menu items, buttons and command names, as in the macOS HIG and the REQUIREMENTS strings ("Keep Mine", "Open With Default App", "New Tab in Folder…"). Prepositions of four letters or fewer stay lowercase ("Go to Line…").
- **State words.** Exactly the §7.1 words: Needs you, Failed, Couldn't start, Working, Running, Done, Starting, Stopping, Stopped. Never "Error", "Busy", "Idle", "Waiting", "Blocked", "Complete" or "Success".
- **Messages.** The title says what happened ("Folder not found", `Couldn't save "session.ts"`). The body gives the reason and the next step in one or two short sentences that name the object. No blame, no "Oops", no exclamation marks.
- **Nouns.** Workspace, tab, pane, agent, shell, file, folder, mapod. Menus call the rail "Sidebar", because that is the system action's title.
- **Characters.** Straight ASCII quotes and apostrophes in every UI string (`Delete "Obsess"?`, "Couldn't start"), so drives can match them and the rail matches the daemon's `stateLabel`. " · " joins metadata. "…" (U+2026) ends commands that ask for more input. "−" (U+2212) marks deletions and "+" additions.
- **Paths, numbers, durations.** Paths use `~` and truncate at the head. Numbers take thousands separators. Durations read "38 s", "4 min" and "1 h 12 min".

## 12. Canvas boards and rejected alternatives

The design canvas is <https://claude.ai/artifact/DXzWX7bnxWX3i2zJCy1A8J>. Local copies of the chosen boards are [design/A-source-list.dc.html](design/A-source-list.dc.html) ("A · Source list", the window, D-10), [design/S2-rail-slimmer.dc.html](design/S2-rail-slimmer.dc.html) ("S2 · Slimmer", the rail, D-16) and [design/attention-and-status.dc.html](design/attention-and-status.dc.html) ("Attention and status").

Where a board and this document disagree, this document wins. The A board's "New Tab ⌘T" rail footer is gone, because S2 has none. Server Restart buttons and `*.localhost` URLs are LATER. Pane headers are 36, not 38. The rail is 280 wide, not 272.

These alternatives were explored and rejected. Do not bring them back without the user.

| Board | Rejected idea |
|---|---|
| B · Workspace strip | A narrow column of two-letter workspace tiles, plus a second column listing the active workspace's tabs grouped as Agents, Servers and Shells. |
| C · Floating glass | Panes fill the window while the rail and inspector float over the terminals as detached glass cards, with inline diff previews inside Changes. |
| A1 · Quiet | Two-line workspace cards with a summary line under the name. Its rule of words only for urgent states lives on in S2. |
| A2 · Context lines | A second line under every tab: last action, command, URL or error. |
| A3 · Roles and server chips | Servers as pill chips in a strip below the tabs, plus workspace summary lines. D-20 rules out chips and a server section. |
| A4 · Cards with tab dots | Workspace cards with a row of per-tab status dots. |
| A5 · Compact, keyboard | Always-visible ⌘N and ⌃N shortcut columns. S2 shows hints only while ⌘ is held, and workspaces get no number shortcuts. |
| A6 · Act from the rail | Inline approve and deny, Restart and Logs buttons inside rail rows. D-16 rules out inline actions. |
| S1 · Slim | 26 and 28 pt rows, status dots overlaid on kind icons, branch and folders on a second line, a server chip row, ⌃N workspace hints. |
