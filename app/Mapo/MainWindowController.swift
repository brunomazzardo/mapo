import AppKit
import MapoClient
import MapoTerminal
import MapoUI

/// Owns the main window: the split view, the toolbar, the title, and the commands the UI runs.
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let client: MapoClient
    private let instance: String
    private var paneArea: PaneAreaViewController?

    private static let railToggleItem = NSToolbarItem.Identifier("rail.toggle")
    private static let newWorkspaceItem = NSToolbarItem.Identifier("rail.newWorkspace")
    private static let inspectorItem = NSToolbarItem.Identifier("toolbar.inspector")

    init(client: MapoClient, registry: SurfaceRegistry) {
        self.client = client
        self.instance = client.store.instance
        let window = MapoWindow()
        super.init(window: window)

        let rail = RailViewController(
            store: client.store,
            actions: RailActions(
                activateWorkspace: { [weak self] id in
                    self?.run("workspace.activate") { try await $0.activateWorkspace(id: id) }
                },
                focusTab: { [weak self] id in
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
                restartDaemon: { [weak self] in self?.restartDaemon() }))
        paneArea = panes
        window.contentViewController = MainSplitViewController(
            rail: rail, panes: panes, inspector: InspectorViewController(), instance: instance)

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
    }

    // MARK: Commands (UX §8)

    func newWorkspace() {
        run("New Workspace") { try await $0.newWorkspace() }
    }

    func newShellTab() {
        run("New Shell Tab") { try await $0.newShellTab() }
    }

    func restartDaemon() {
        Task { await client.restartDaemon() }
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
            .flexibleSpace, Self.railToggleItem, Self.newWorkspaceItem, .sidebarTrackingSeparator, .flexibleSpace,
            Self.inspectorItem, .inspectorTrackingSeparator,
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
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
            target: nil, action: action)
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
