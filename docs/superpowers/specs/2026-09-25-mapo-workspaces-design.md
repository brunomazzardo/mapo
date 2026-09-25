# Mapo: cmux-style workspaces on the VS Code workbench

Date: 2026-09-25
Status: approved in chat, spec written for implementation planning

## Goal

Turn this VS Code fork ("Mapo") into a terminal and agent hub shaped like cmux:

- Left: a list of user-created **workspaces**. A workspace is a named group of tabs. It needs no folder.
- Center: the workspace's **tabs**. Every tab is a terminal. A "Claude" tab is a terminal that launches the `claude` CLI in a chosen folder.
- Right: a **file explorer rooted at the focused terminal's current directory**. Clicking a file opens it in an editor split beside the terminal, with the usual VS Code editing, git gutter, and diff features.

The normal VS Code chrome (activity bar, default Explorer/Search/SCM side bar, panel, status bar) is hidden. Command palette, settings, keybindings, and extensions still work.

## Non-goals for v1

- Creating git worktrees or branches from the UI.
- Desktop notifications.
- Dragging tabs between workspaces.
- Reconnecting to terminal processes after an app restart. Tabs are relaunched from their saved kind and folder.
- Packaging a signed `.app`. Deliverable is a running dev build.

## Approach

One new workbench contribution folder, `src/vs/workbench/contrib/mapo/`, plus product and default-setting changes. No edits to the workbench layout engine. Upstream merges stay cheap.

## Components

### 1. Chrome and layout (`mapo.contribution.ts`, `product.json`)

- `product.json`: `nameShort` and `nameLong` become "Mapo". Other identifiers stay as they are so dev launch keeps working.
- Default configuration overrides registered through the configuration registry's `registerDefaultConfigurations`:
  - `workbench.activityBar.location`: `hidden`
  - `workbench.statusBar.visible`: `false`
  - `workbench.secondarySideBar.defaultVisibility`: `visible`
  - `workbench.startupEditor`: `none`
  - `workbench.editor.showTabs`: `multiple`
  - `terminal.integrated.defaultLocation`: `editor`
  - `terminal.integrated.enableVisualBell`: `true`
  - `git.autoRepositoryDetection`: `true` (already the default, kept explicit; it detects repos from open editors)
- A startup contribution (`WorkbenchPhase.AfterRestored`) opens the Workspaces view container in the primary side bar, ensures the auxiliary bar is visible with the Mapo Explorer view, hides the panel, and restores the last active workspace.

### 2. Workspace model and service (`common/mapoWorkspace.ts`, `browser/mapoWorkspaceService.ts`)

```ts
interface IMapoTab {
  id: string;            // stable uuid
  kind: 'terminal' | 'claude';
  cwd: string;           // absolute path used at launch
  title?: string;        // user override; otherwise terminal title
}
interface IMapoWorkspace {
  id: string;
  name: string;
  tabs: IMapoTab[];
  activeTabId?: string;
}
interface IMapoWorkspaceService {
  readonly workspaces: readonly IMapoWorkspace[];
  readonly activeWorkspace: IMapoWorkspace | undefined;
  readonly onDidChange: Event<void>;
  createWorkspace(name: string): IMapoWorkspace;
  renameWorkspace(id: string, name: string): void;
  deleteWorkspace(id: string): Promise<void>;     // disposes its terminals
  activateWorkspace(id: string): Promise<void>;
  createTab(workspaceId: string, kind: IMapoTab['kind'], cwd: string): Promise<void>;
  closeTab(workspaceId: string, tabId: string): Promise<void>;
  getInstance(tabId: string): ITerminalInstance | undefined;
  getTabForInstance(instance: ITerminalInstance): { workspace: IMapoWorkspace; tab: IMapoTab } | undefined;
}
```

- Persistence: JSON in `IStorageService`, scope `APPLICATION`, target `MACHINE`, key `mapo.workspaces`. Saved on every change.
- Runtime map `tabId -> ITerminalInstance`. Instances are created with `ITerminalService.createTerminal({ cwd, location: TerminalLocation.Editor, config })`. For `claude` tabs the shell launch config runs the user's default shell with `claude` as the executable found on `PATH` (`executable: 'claude'`, `args: []`, `name: 'Claude'`, `icon: Codicon.sparkle`). If the launch fails the terminal shows the error the way VS Code already does.
- When an instance exits or is disposed, its tab is removed from the model.

### 3. Workspace switching

Switching uses two existing terminal editor service calls:

- Leaving a workspace: for each of its instances, `ITerminalEditorService.detachInstance(instance)`. This closes the editor tab but keeps the process and xterm buffer alive.
- Entering a workspace: for each tab in order, `ITerminalEditorService.openEditor(instance, { preserveFocus: true })`, then focus the active tab.
- Non-terminal editors (files opened from the explorer) are closed on switch. Their group layout is not preserved in v1.
- First-run: an empty workspace list shows a welcome message with a "Create workspace" link in the Workspaces view.

### 4. Workspaces view (`browser/mapoWorkspacesView.ts`)

- A `ViewPane` in its own view container, `mapo.workspaces`, registered to `ViewContainerLocation.Sidebar`. The container is opened at startup, so it is what the primary side bar shows.
- A `WorkbenchList` of workspaces. Each row shows name, status line, and the folder and git branch of the active tab. The branch is read from `.git/HEAD` (walking up from the cwd) with `IFileService`, re-read when the cwd changes.
- Status line, best effort:
  - "Waiting for input" when the active tab's `statusList` contains the `bell` status, or when its shell-integration command detection reports no running command and the terminal is a `claude` tab.
  - "Running" otherwise while a command is running.
  - "Idle" for plain shells with no running command.
- Actions in the view title: New Workspace. Context menu per row: New Terminal Tab, New Claude Tab, Rename, Delete.
- New tab prompts for a folder with `IFileDialogService.showOpenDialog`, default path is the workspace's most recent tab cwd, else the home folder.
- Commands, all also in the command palette:
  - `mapo.workspace.new`, `mapo.workspace.rename`, `mapo.workspace.delete`
  - `mapo.tab.newTerminal`, `mapo.tab.newClaude`
  - `mapo.workspace.next` / `mapo.workspace.previous` (Cmd+Shift+] / Cmd+Shift+[ on macOS, Ctrl+ elsewhere)

### 5. Cwd explorer (`browser/mapoExplorerView.ts`)

- A `ViewPane` in view container `mapo.explorer`, registered to `ViewContainerLocation.AuxiliaryBar`.
- Its own tree: `WorkbenchAsyncDataTree` over a small `FileNode { resource: URI; isDirectory: boolean; name: string }` type, using `ResourceLabels` for icons and names, `IFileService.resolve` as the data source, folders first then alphabetical. Hidden files follow `files.exclude`. It does not reuse VS Code's Explorer classes, which are bound to workspace folders.
- Root selection: the focused terminal instance (from `ITerminalService.onDidChangeActiveInstance` and the terminal editor service's focus event). Root is `capabilities.get(TerminalCapability.CwdDetection)?.getCwd()`, falling back to the tab's saved cwd. It updates on `onDidChangeCwd`.
- The view title shows the root folder name; the header tooltip shows the full path.
- Clicking a file: `IEditorService.openEditor({ resource }, SIDE_GROUP)` when the active group holds a terminal editor, otherwise `ACTIVE_GROUP`. Result: the editor appears in a group to the right of the terminal and stays there for later files.
- Refresh on `IFileService.onDidFilesChange` for the root subtree, debounced.
- A Refresh action and a "Reveal in Finder" action in the view title.

### 6. Error handling

- Terminal launch failure: tab stays in the model, the terminal shows the launch error, status "Exited".
- Explorer root missing on disk: the view shows "Folder not found: <path>" instead of a tree.
- Corrupt persisted state: log and start with an empty workspace list.

### 7. Testing

- Unit tests under `src/vs/workbench/contrib/mapo/test/browser/`:
  - `mapoWorkspaceService.test.ts`: create, rename, delete, activate, persistence round-trip, tab removal on instance dispose. Terminal service and editor service are stubbed.
  - `mapoExplorerDataSource.test.ts`: sorting, hidden-file filtering, missing root.
- Manual acceptance from `./scripts/code.sh`:
  1. App opens with Workspaces on the left, empty tab area, Explorer on the right, no activity bar or status bar.
  2. Create workspace "A", add a Claude tab in `~/code/mapo`. The explorer shows that folder. The tab title follows the process title.
  3. Add a terminal tab, `cd` somewhere. The explorer follows.
  4. Click a file. It opens split to the right of the terminal. Git gutter decorations appear for a tracked file.
  5. Create workspace "B" with its own tab. Switch A/B. Terminal contents survive the switch.
  6. Quit and relaunch. Both workspaces and their tabs come back, terminals relaunched in their folders.

## Build and delivery

- Node 24.18.0 via mise. Install with `npm ci`, compile with `npm run compile-client` or `npm run watch-client`, run with `./scripts/code.sh`.
- Done means the six manual steps above pass on this machine and unit tests pass.
