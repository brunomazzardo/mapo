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
    /// Serves `explorer.*` (PROTOCOL §6.5).
    let inspector: InspectorViewController

    private static let titleItem = NSToolbarItem.Identifier("toolbar.title")
    private static let railToggleItem = NSToolbarItem.Identifier("rail.toggle")
    private static let newWorkspaceItem = NSToolbarItem.Identifier("rail.newWorkspace")
    private static let inspectorItem = NSToolbarItem.Identifier("toolbar.inspector")

    init(client: MapoClient, registry: SurfaceRegistry, metrics: UIMetrics) {
        self.client = client
        self.instance = client.store.instance
        self.metrics = metrics
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
                newWorkspace: { [weak self] in self?.newWorkspace() }))
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
        window.onLeftMouseDown = { [weak panes] event in panes?.windowMouseDown(event) }
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
        let id = workspaces[current + offset].id
        metrics.beginWorkspaceSwitch(to: id)
        paneArea?.expectFocusChange()
        run("workspace.activate") { try await $0.activateWorkspace(id: id) }
    }

    var hasFocusedTab: Bool { focusedTab != nil }
    var focusedTabIsRunning: Bool { focusedTab?.state == .running }
    var hasActiveWorkspace: Bool { client.store.activeWorkspace != nil }

    /// `ui.visibility`; a failure only logs.
    private func reportVisibility(keyWindow: Bool, visibleTabIds: [String], focusedTabId: String?) {
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
