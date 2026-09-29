import AppKit
import MapoAutomation
import MapoClient
import MapoProtocol
import MapoTerminal
import MapoUI

/// Owns the main window: the split view, the toolbar, the title, and the commands the UI runs.
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let client: MapoClient
    private let instance: String
    private let metrics: UIMetrics
    private var paneArea: PaneAreaViewController?
    private var rail: RailViewController?
    /// The ⌘K palette (UX §10).
    private var palette: PaletteController?
    private let registry: SurfaceRegistry
    /// `[terminal] font-size` at launch; Actual Size (⌘0) returns to it.
    private let baseFontSize: Double
    /// The terminals' font size now: Bigger and Smaller step it by 1 pt from 9 to 24, not saved (UX §8).
    private var fontSize: Double
    /// Serves `explorer.*` (PROTOCOL §6.5).
    let inspector: InspectorViewController
    /// The dock badge and notifications (PLAN T2.4).
    private var attention: AttentionController?
    /// The tabs in the shown panes, as last sent in `ui.visibility`.
    private var visibleTabIds: Set<String> = []

    private static let titleItem = NSToolbarItem.Identifier("toolbar.title")
    private static let railToggleItem = NSToolbarItem.Identifier("rail.toggle")
    private static let newWorkspaceItem = NSToolbarItem.Identifier("rail.newWorkspace")
    private static let inspectorItem = NSToolbarItem.Identifier("toolbar.inspector")

    init(client: MapoClient, registry: SurfaceRegistry, metrics: UIMetrics) {
        self.client = client
        self.instance = client.store.instance
        self.metrics = metrics
        self.registry = registry
        self.baseFontSize = registry.settings.fontSize
        self.fontSize = registry.settings.fontSize
        // `[ui]` appearance and Reduce Transparency, before any view resolves a color (UX §9, PLAN T1.9).
        Theme.apply(AppearanceSettings(instanceDirectory: client.configuration.instance.dataDirectory))
        self.inspector = InspectorViewController(client: client)
        let window = MapoWindow()
        super.init(window: window)

        let rail = RailViewController(
            store: client.store,
            actions: RailActions(
                activateWorkspace: { [weak self] id in
                    self?.metrics.beginWorkspaceSwitch(to: id)
                    self?.run("workspace.activate") { try await $0.activateWorkspace(id: id) }
                },
                focusTab: { [weak self] id in
                    self?.metrics.beginTabFocus(id)
                    self?.run("tab.focus") { client in
                        try await client.focusTab(id: id)
                        self?.paneArea?.focusTerminal()
                    }
                },
                newWorkspace: { [weak self] in self?.newWorkspace() },
                newTabInFolder: { [weak self] id in self?.newTabInFolder(workspaceId: id) },
                setAgentCommand: { [weak self] id in self?.setAgentCommand(workspaceId: id) }))
        self.rail = rail
        let panes = PaneAreaViewController(
            store: client.store, registry: registry,
            actions: PaneAreaActions(
                newShellTab: { [weak self] in self?.newShellTab() },
                restartDaemon: { [weak self] in self?.restartDaemon() },
                perform: { [weak self] name, body in self?.run(name, body) },
                closeTab: { [weak self] id in self?.closeTab(id: id) },
                reportVisibility: { [weak self] key, visible, focused in
                    self?.reportVisibility(keyWindow: key, visibleTabIds: visible, focusedTabId: focused)
                }))
        paneArea = panes
        palette = PaletteController(
            store: client.store,
            actions: PaletteActions(
                focusTab: { [weak self] id in self?.focusTab(id) },
                showTabToTheRight: { [weak self] id in
                    self?.run("Show to the Right") { try await $0.showTab(id: id, direction: "right") }
                },
                activateWorkspace: { [weak self] id in self?.activateWorkspace(id) },
                openFile: { [weak self] path in self?.openFile(path) },
                perform: { [weak self] command in self?.perform(command) },
                isEnabled: { [weak self] command in self?.isEnabled(command) ?? false }))
        // A click outside the palette closes it (UX §10); clicks inside it go to its own panel.
        window.onLeftMouseDown = { [weak self, weak panes] event in
            self?.palette?.close()
            panes?.windowMouseDown(event)
        }
        window.contentViewController = MainSplitViewController(
            rail: rail, panes: panes, inspector: inspector, instance: instance)

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let autosave = "main-\(instance)"
        if !window.setFrameUsingName(autosave) {
            window.setContentSize(MapoWindow.defaultSize)
            window.center()
        }
        window.setFrameAutosaveName(autosave)
        observeContinuously(self) { $0.updateTitle() }
        attention = AttentionController(
            client: client, canSee: { [weak self] tab in self?.canSee(tab) ?? false },
            focusTab: { [weak self] id in self?.focusTab(id) })
    }

    /// Whether the person can see a tab: Mapo is active, the window is on screen and not occluded, and the tab
    /// is in a shown pane of the active workspace (UX §7.3).
    private func canSee(_ tab: TabSummary) -> Bool {
        guard NSApp.isActive, let window, window.isVisible, !window.isMiniaturized,
            window.occlusionState.contains(.visible)
        else { return false }
        return tab.workspaceId == client.store.activeWorkspaceId && visibleTabIds.contains(tab.id)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is built in code")
    }

    /// The active workspace's name, plus ` (<instance>)` outside `main` (UX §2, ENGINEERING §2.6).
    private func updateTitle() {
        let name = client.store.activeWorkspace?.name ?? "Mapo"
        window?.title = instance == "main" ? name : "\(name) (\(instance))"
        window?.setAccessibilityLabel(window?.title)
    }

    // MARK: Commands (UX §8)

    func newWorkspace() {
        metrics.beginWorkspaceCreate()
        paneArea?.expectFocusChange()
        run("New Workspace") { try await $0.newWorkspace() }
    }

    func newShellTab() {
        metrics.beginTabCreate()
        paneArea?.expectFocusChange()
        run("New Shell Tab") { try await $0.newShellTab() }
    }

    /// New Agent Tab (⇧⌘T): the workspace's agent command in a new shell, focused (PLAN T2.3).
    func newAgentTab() {
        metrics.beginTabCreate()
        paneArea?.expectFocusChange()
        run("New Agent Tab") { try await $0.newAgentTab() }
    }

    /// Interrupt Agent (⇧⌘X): Esc to the focused tab's working agent.
    func interruptAgent() {
        guard let tab = focusedTab, tab.isAgent, tab.state == .running else { return NSSound.beep() }
        run(Method.tabInterrupt) { try await $0.tabCommand(Method.tabInterrupt, id: tab.id) }
    }

    /// Next Tab That Needs You (⌘J): the next attention tab after the focused one, wrapping (UX §7.4).
    func focusNextAttentionTab() {
        guard let tab = AttentionController.nextAttentionTab(client.store, after: focusedTab?.id) else {
            return NSSound.beep()
        }
        focusTab(tab.id)
    }

    func restartDaemon() {
        Task { await client.restartDaemon() }
    }

    // MARK: Pane and workspace commands (UX §4.2, §8)

    /// The active workspace's focused tab.
    private var focusedTab: TabSummary? {
        let store = client.store
        guard let workspaceId = store.activeWorkspaceId, let id = store.focusedTabId(inWorkspace: workspaceId)
        else { return nil }
        return store.tabs[id]
    }

    /// Split Right (⌘D) or Split Down (⇧⌘D). A split that would leave a pane under 200×120 beeps.
    func splitPane(_ direction: String) {
        guard client.store.activeWorkspace != nil else { return newShellTab() }
        guard paneArea?.canSplitFocusedPane(direction) ?? true else { return NSSound.beep() }
        metrics.beginPaneSplit()
        paneArea?.expectFocusChange()
        run("pane.split") { try await $0.splitPane(direction: direction) }
    }

    /// Close Pane (⌘W): the tab keeps running.
    func closePane() {
        run("pane.close") { try await $0.closePane() }
    }

    /// ⌥⌘ plus an arrow.
    func focusPane(_ direction: String) {
        paneArea?.expectFocusChange()
        run("pane.focus") { try await $0.focusPane(direction: direction) }
    }

    func equalizePanes() {
        run("pane.equalize") { try await $0.equalizePanes() }
    }

    /// Close Tab (⇧⌘W) on the focused tab.
    func closeFocusedTab() {
        guard let tab = focusedTab else { return NSSound.beep() }
        closeTab(id: tab.id)
    }

    /// Close Tab with the R-TAB-7 confirmation when a program or command runs (UX §3.5).
    func closeTab(id: String) {
        guard let tab = client.store.tabs[id] else { return }
        let busy = tab.program != nil || tab.state == .running
        guard busy, let window else {
            run("tab.close") { try await $0.closeTab(id: id, force: busy) }
            return
        }
        Task {
            let what = tab.program ?? "A command"
            let confirmed = await ConfirmSheet.confirm(
                on: window, title: "Close \"\(tab.name)\"?",
                message: "\(what) is still running in this tab. Closing the tab stops it.", confirm: "Close Tab")
            guard confirmed else { return }
            run("tab.close") { try await $0.closeTab(id: id, force: true) }
        }
    }

    /// Stop Command (⌘.): Ctrl-C to the focused tab's command.
    func stopCommand() {
        guard let tab = focusedTab, tab.state == .running else { return NSSound.beep() }
        run("tab.stop") { try await $0.tabCommand("tab.stop", id: tab.id) }
    }

    /// Previous or Next Workspace (⌃⌘↑, ⌃⌘↓): rail order, no wrap.
    func switchWorkspace(by offset: Int) {
        let workspaces = client.store.workspaces
        guard let current = workspaces.firstIndex(where: { $0.id == client.store.activeWorkspaceId }),
            workspaces.indices.contains(current + offset)
        else { return NSSound.beep() }
        activateWorkspace(workspaces[current + offset].id)
    }

    /// Makes a workspace active and moves keyboard focus into its focused pane.
    private func activateWorkspace(_ id: String) {
        metrics.beginWorkspaceSwitch(to: id)
        paneArea?.expectFocusChange()
        run("workspace.activate") { try await $0.activateWorkspace(id: id) }
    }

    var hasFocusedTab: Bool { focusedTab != nil }
    var focusedTabIsRunning: Bool { focusedTab?.state == .running }
    var hasActiveWorkspace: Bool { client.store.activeWorkspace != nil }

    /// `ui.visibility`; a failure only logs.
    private func reportVisibility(keyWindow: Bool, visibleTabIds: [String], focusedTabId: String?) {
        self.visibleTabIds = Set(visibleTabIds)
        let client = client
        Task {
            do {
                try await client.reportVisibility(
                    keyWindow: keyWindow, visibleTabIds: visibleTabIds, focusedTabId: focusedTabId)
            } catch {
                MapoLog.shared.debug("ui.visibility failed: \(error)")
            }
        }
    }

    var isConnected: Bool { client.store.isConnected }

    /// Runs a daemon command. A failure is logged and beeps; `app.notice` (T1.x) will show the message.
    private func run(_ name: String, _ body: @escaping (MapoClient) async throws -> Void) {
        let client = client
        Task {
            do {
                try await body(client)
            } catch {
                MapoLog.shared.warn("\(name) failed: \(error)")
                NSSound.beep()
            }
        }
    }

    // MARK: Palette, view and menu commands (UX §8, §10)

    /// ⌘K opens or closes the palette over the panes area.
    func togglePalette() {
        guard let window, let palette else { return }
        palette.toggle(in: window, over: paneArea?.view)
        if palette.isOpen { metrics.begin(.paletteOpen) { true } }
    }

    /// Focuses a tab, in any workspace, and gives its pane keyboard focus.
    private func focusTab(_ id: String) {
        metrics.beginTabFocus(id)
        paneArea?.expectFocusChange()
        run("tab.focus") { [weak self] client in
            try await client.focusTab(id: id)
            self?.paneArea?.focusTerminal()
        }
    }

    /// `file.open`: the file in a file pane (UX §6).
    private func openFile(_ path: String) {
        run("file.open") { _ = try await $0.openFile(path: path) }
    }

    /// Settings… (⌘,) opens this instance's `config.toml` in a file pane, first creating it with the keys
    /// as comments (D-30).
    func openSettings() {
        let url = client.configuration.instance.dataDirectory.appending(component: "config.toml")
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try Self.configTemplate.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                MapoLog.shared.warn("can't create \(url.path): \(error)")
                return NSSound.beep()
            }
        }
        openFile(url.path)
    }

    private static let configTemplate = """
        # Mapo settings for this instance. Uncomment a line to change it.

        [terminal]
        # font-family = "SF Mono"
        # font-size = 12.5
        # option-as-alt = false

        [ui]
        # appearance = "system"

        """

    /// New Tab in Folder… (⌥⌘T, or a workspace row's menu): the folder sheet, then a shell there in the
    /// workspace's focused pane. The sheet starts at that workspace's focused tab's folder.
    func newTabInFolder(workspaceId: String? = nil) {
        guard let window, let workspaceId = workspaceId ?? client.store.activeWorkspaceId else { return }
        let store = client.store
        let folder = store.focusedTabId(inWorkspace: workspaceId).flatMap { store.tabs[$0]?.cwd } ?? NSHomeDirectory()
        Task {
            guard let path = await FolderSheet.choose(on: window, initialFolder: folder) else { return }
            metrics.beginTabCreate()
            paneArea?.expectFocusChange()
            run("New Tab in Folder") { client in
                _ = try await client.call(
                    Method.tabCreate,
                    TabCreateParams(
                        workspace: workspaceId, kind: "shell", cwd: path, placement: "focused", focus: true),
                    as: TabSummary.self)
            }
        }
    }

    /// Set Agent Command… (the Workspace menu, or a workspace row's menu): the command sheet, then
    /// `workspace.configure`.
    func setAgentCommand(workspaceId: String? = nil) {
        guard let window, let id = workspaceId ?? client.store.activeWorkspaceId,
            let workspace = client.store.workspace(id: id)
        else { return NSSound.beep() }
        Task {
            guard
                let command = await AgentCommandSheet.choose(
                    on: window, workspaceName: workspace.name, current: workspace.agentCommand)
            else { return }
            run("Set Agent Command") { try await $0.setAgentCommand(workspaceId: id, command: command) }
        }
    }

    /// Bigger (+1), Smaller (-1), or Actual Size (nil): every terminal, 9 to 24 pt.
    func changeFontSize(by step: Double?) {
        let size = step.map { min(24, max(9, fontSize + $0)) } ?? baseFontSize
        guard size != fontSize else { return }
        fontSize = size
        registry.setFontSize(size)
    }

    /// Show Files and Show Changes select the segment and open a hidden inspector.
    func showInspector(_ segment: InspectorViewController.Segment) {
        inspector.select(segment)
        guard let split = window?.contentViewController as? NSSplitViewController,
            split.splitViewItems.last?.isCollapsed == true
        else { return }
        split.toggleInspector(nil)
    }

    /// Renaming happens in the rail, which opens if hidden (UX §8).
    private func showRail() {
        guard let split = window?.contentViewController as? NSSplitViewController,
            split.splitViewItems.first?.isCollapsed == true
        else { return }
        split.toggleSidebar(nil)
        window?.layoutIfNeeded()
    }

    /// Rename Tab (⌥⌘R): the focused tab's rail row turns into `rail.rename`.
    func renameFocusedTab() {
        guard let tab = focusedTab else { return NSSound.beep() }
        showRail()
        rail?.beginRename(tabId: tab.id)
    }

    func renameActiveWorkspace() {
        guard let id = client.store.activeWorkspaceId else { return NSSound.beep() }
        showRail()
        rail?.beginRename(workspaceId: id)
    }

    /// Move Workspace Up (-1) or Down (+1) in the rail.
    func moveActiveWorkspace(by offset: Int) {
        let workspaces = client.store.workspaces
        guard let index = workspaces.firstIndex(where: { $0.id == client.store.activeWorkspaceId }),
            workspaces.indices.contains(index + offset)
        else { return NSSound.beep() }
        let id = workspaces[index].id
        run("workspace.move") { try await $0.moveWorkspace(id: id, to: index + offset) }
    }

    /// Delete Workspace, with the rail's confirmation (UX §3.5).
    func deleteActiveWorkspace() {
        guard let id = client.store.activeWorkspaceId else { return NSSound.beep() }
        rail?.deleteWorkspace(id: id)
    }

    /// The active workspace's tabs in rail order.
    private var activeTabs: [TabSummary] {
        client.store.activeWorkspaceId.map { client.store.tabs(inWorkspace: $0) } ?? []
    }

    /// Previous Tab (-1) and Next Tab (+1): rail order within the workspace, wrapping.
    func switchTab(by offset: Int) {
        let tabs = activeTabs
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0.id == focusedTab?.id }) else {
            return NSSound.beep()
        }
        focusTab(tabs[(current + offset + tabs.count) % tabs.count].id)
    }

    /// Go to Tab N (⌘1 to ⌘9).
    func goToTab(_ number: Int) {
        let tabs = activeTabs
        guard tabs.indices.contains(number - 1) else { return NSSound.beep() }
        focusTab(tabs[number - 1].id)
    }

    // MARK: Command table plumbing (T1.8)

    /// Runs a table command from the palette the way its menu item would.
    private func perform(_ command: Command) {
        guard let target = target(for: command) else { return NSSound.beep() }
        NSApp.sendAction(command.action, to: target, from: menuItem(for: command))
    }

    /// Whether the palette lists a command: its feature exists and its target validates it now.
    private func isEnabled(_ command: Command) -> Bool {
        guard command.milestone == nil, let target = target(for: command) else { return false }
        let item = menuItem(for: command)
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    private func menuItem(for command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
        item.tag = command.tag
        return item
    }

    /// Where a command goes, as if the main window were key (the palette has just closed, or the app is
    /// inactive while a drive runs it): editor actions to a text view's chain, others along the first
    /// responder's chain preferring a controller (NSSplitView answers the toggles but only acts while key),
    /// then the split view controller and the app delegate.
    private func target(for command: Command) -> AnyObject? {
        let action = command.action
        let chain = sequence(first: window?.firstResponder, next: { $0?.nextResponder }).compactMap { $0 }
        if command.method == "editor" {
            guard chain.contains(where: { ($0 as? NSTextView)?.isFieldEditor == false }) else { return nil }
            return chain.first { $0.responds(to: action) }
        }
        let handlers = chain.filter { $0.responds(to: action) }
        if let controller = handlers.first(where: { $0 is NSViewController || $0 is NSWindowController }) {
            return controller
        }
        if let handler = handlers.first { return handler }
        if let split = window?.contentViewController, split.responds(to: action) { return split }
        if let delegate = NSApp.delegate, delegate.responds(to: action) { return delegate }
        return nil
    }

    /// Enables the Mapo items of the menu bar (UX §8). Items of later milestones stay disabled.
    func validate(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, !CommandTable.isLater(action) else { return false }
        let store = client.store
        let connected = store.isConnected
        let workspaces = store.workspaces
        let active = workspaces.firstIndex { $0.id == store.activeWorkspaceId }
        typealias A = MapoCommandActions
        switch action {
        case #selector(A.togglePalette(_:)), #selector(A.showFiles(_:)), #selector(A.showChanges(_:)):
            return true
        case #selector(A.biggerFont(_:)):
            return fontSize < 24
        case #selector(A.smallerFont(_:)):
            return fontSize > 9
        case #selector(A.actualSizeFont(_:)):
            return fontSize != baseFontSize
        case #selector(A.openSettings(_:)), #selector(A.newWorkspace(_:)), #selector(A.newShellTab(_:)):
            return connected
        case #selector(A.moveWorkspaceUp(_:)):
            return connected && (active ?? 0) > 0
        case #selector(A.moveWorkspaceDown(_:)):
            return connected && active.map { $0 < workspaces.count - 1 } ?? false
        case #selector(A.previousTab(_:)), #selector(A.nextTab(_:)):
            return connected && activeTabs.count > 1
        case #selector(A.goToTab(_:)):
            let tabs = activeTabs
            let tab = tabs.indices.contains(item.tag - 1) ? tabs[item.tag - 1] : nil
            // "1  be-claude" (UX §8).
            item.title =
                tab.map { "\(item.tag)  \($0.labeled || $0.title.isEmpty ? $0.name : $0.title)" } ?? "Tab \(item.tag)"
            return connected && tab != nil
        case #selector(A.renameTab(_:)), #selector(A.closeTab(_:)):
            return connected && focusedTab != nil
        case #selector(A.stopCommand(_:)):
            return connected && focusedTab?.state == .running
        case #selector(A.interruptAgent(_:)):
            return connected && focusedTab.map { $0.isAgent && $0.state == .running } ?? false
        case #selector(A.nextTabNeedingYou(_:)):
            return connected && !AttentionController.attentionOrder(store).isEmpty
        default:
            // Workspace, pane and New Tab in Folder commands need an active workspace.
            return connected && active != nil
        }
    }

    /// `ui.snapshot` model fields for drives (ENGINEERING §4.4): `view`, the view-only state the menus
    /// change, `commands`, the command table the `task-t1-8` drive walks, and `editors`, the open editors'
    /// highlighting.
    func automationModel() -> [String: JSONValue] {
        let split = window?.contentViewController as? NSSplitViewController
        let view: [String: JSONValue] = [
            "fontSize": .number(fontSize),
            "sidebar": .bool(split?.splitViewItems.first?.isCollapsed == false),
            "inspector": .bool(split?.splitViewItems.last?.isCollapsed == false),
            "inspectorSegment": .string(inspector.segment.rawValue),
            "palette": .bool(palette?.isOpen ?? false),
        ]
        let commands = CommandTable.checklist.map { JSONValue.object($0.mapValues(JSONValue.string)) }
        return [
            "view": .object(view), "commands": .array(commands),
            "dockBadge": .number(Double(attention?.dockBadge ?? 0)),
            "dockBadgeLabel": .string(NSApp.dockTile.badgeLabel ?? ""),
            "editors": FileEditors.automationModel(),
        ]
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace, Self.railToggleItem, Self.newWorkspaceItem, .sidebarTrackingSeparator, Self.titleItem,
            .flexibleSpace, Self.inspectorItem, .inspectorTrackingSeparator,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.titleItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = ToolbarTitleView(store: client.store)
            item.label = "Workspace"
            item.isBordered = false
            return item
        case Self.railToggleItem:
            return button(
                itemIdentifier, symbol: "sidebar.left", label: "Toggle Sidebar", tooltip: "Hide Sidebar (⌃⌘S)",
                action: #selector(NSSplitViewController.toggleSidebar(_:)), axid: AXID.railToggle)
        case Self.newWorkspaceItem:
            return button(
                itemIdentifier, symbol: "plus", label: "New Workspace", tooltip: "New Workspace (⇧⌘N)",
                action: #selector(AppDelegate.newWorkspace(_:)), axid: AXID.railNewWorkspace)
        case Self.inspectorItem:
            return button(
                itemIdentifier, symbol: "sidebar.right", label: "Toggle Inspector", tooltip: "Hide Inspector (⌥⌘0)",
                action: #selector(NSSplitViewController.toggleInspector(_:)), axid: AXID.toolbarInspector)
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, symbol: String, label: String, tooltip: String, action: Selector,
        axid: String
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        // The split view controller handles the sidebar and inspector toggles. Targeting it directly, not the
        // responder chain, keeps the buttons working while the app is inactive and `ui click` drives them.
        let splitViewController = window?.contentViewController as? NSSplitViewController
        let target: AnyObject? = splitViewController?.responds(to: action) == true ? splitViewController : nil
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
            target: target, action: action)
        button.bezelStyle = .toolbar
        button.toolTip = tooltip
        button.setAXIdentifier(axid)
        button.setAccessibilityLabel(label)
        item.view = button
        item.label = label
        item.toolTip = tooltip
        return item
    }
}
