import AppKit
import MapoClient
import MapoProtocol

/// The Files segment (UX §5.2, PLAN T1.5): a tree rooted at the folder of the last focused tab, loaded one
/// level at a time through `fs.list`, kept current by `fs.watch` on the root and every expanded folder.
///
/// It re-roots without taking focus: nothing here calls `makeFirstResponder`. Every listing carries a
/// request number per folder and the root generation, so a newer refresh supersedes an older one and a
/// listing for a previous root is dropped.
public final class FilesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate
{
    private enum Methods {
        static let list = "fs.list"
        static let watch = "fs.watch"
        static let unwatch = "fs.unwatch"
    }

    private let client: MapoClient
    private let log = MapoLog.shared
    private let header = FilesHeaderView()
    private let outline = FilesOutlineView()
    private let scroll = NSScrollView()
    private let stateView = FilesStateView()

    /// The folder the tree shows, as the tab reports it.
    public private(set) var root: String?
    private(set) var state: FilesState = .noTerminal
    private var nodes: [FileNode] = []
    private var hiddenByExclude = 0
    private var repoRoot: String?
    /// Relative paths of expanded folders per root, kept for the session (UX §5.2).
    private var expansion: [String: Set<String>] = [:]
    /// Folders watched on the current connection.
    private var watched: Set<String> = []
    /// Bumped on every re-root; listings for an older generation are dropped.
    private var generation = 0
    /// The newest request per folder; an answer to an older one is dropped.
    private var requests: [String: Int] = [:]
    private var nextRequest = 0
    private var rootTimer: Task<Void, Never>?
    private var missingPoll: Task<Void, Never>?
    private var connectedBoot: String?
    private var rootStarted: ContinuousClock.Instant?
    private var isRestoringExpansion = false
    /// Accessibility stand-ins for rows without row views, by node.
    private var rowElements: [ObjectIdentifier: FilesRowElement] = [:]

    public init(client: MapoClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FilesViewController is built in code")
    }

    public override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowSizeStyle = .custom
        outline.rowHeight = FilesMetrics.rowHeight
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.allowsTypeSelect = true
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.onReturn = { [weak self] in self?.openSelection() }
        outline.onUnhandledClick = { [weak self] row in
            guard let self, let node = outline.item(atRow: row) as? FileNode else { return }
            activate(node)
        }
        outline.accessibilityRow = { [weak self] row in self?.rowElement(row) }
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityLabel("Files")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        stateView.onRetry = { [weak self] in self?.retry() }

        let root = NSView()
        root.prefersCompactControlSizeMetrics = true
        for view in [header, scroll, stateView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            stateView.topAnchor.constraint(equalTo: header.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        view = root
        header.configure(path: nil, branch: nil)
        show(.noTerminal)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        client.addEventListener { [weak self] event in self?.handle(event) }
        observeContinuously(self) { $0.follow() }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        outline.sizeLastColumnToFit()
    }

    // MARK: Following the focused tab (R-FS-2)

    /// The folder of the tab in the active workspace's focused pane, else of its active tab: when a file
    /// pane has focus, the last focused tab wins.
    private var targetFolder: String? {
        let store = client.store
        guard let workspaceId = store.activeWorkspaceId,
            let tabId = store.focusedTabId(inWorkspace: workspaceId), let tab = store.tabs[tabId]
        else { return nil }
        let cwd = tab.cwd.isEmpty ? (tab.launch?.cwd ?? "") : tab.cwd
        return cwd.isEmpty ? nil : cwd
    }

    private func follow() {
        let boot: String? = if case .connected(let bootId) = client.store.connection { bootId } else { nil }
        var target = targetFolder
        // A focused file or diff pane keeps the last focused tab's folder (R-FS-2).
        if target == nil, let workspaceId = client.store.activeWorkspaceId,
            client.store.focusedPane(inWorkspace: workspaceId).content.isFile
        {
            target = root
        }
        if boot != connectedBoot {
            connectedBoot = boot
            // Watches are per connection: a new one starts with none.
            watched.removeAll()
            if boot != nil, target == root, root != nil {
                refreshAll()
                return
            }
        }
        guard target != root else { return }
        setRoot(target)
    }

    private func setRoot(_ path: String?) {
        for folder in watched { send(Methods.unwatch, folder) }
        watched.removeAll()
        generation += 1
        requests.removeAll()
        missingPoll?.cancel()
        root = path
        nodes = []
        rowElements.removeAll()
        repoRoot = nil
        hiddenByExclude = 0
        outline.reloadData()
        header.configure(path: path, branch: nil)
        guard let path else {
            rootTimer?.cancel()
            show(.noTerminal)
            return
        }
        rootStarted = .now
        // Before the connection is up, `follow` lists the root once it connects.
        if client.store.isConnected { startRootLoad(path) } else { hideAll() }
    }

    /// Lists the root. Shows "Loading…" only after 300 ms, and retries a listing still unfinished after 4 s
    /// (UX §5.2, PA-32).
    private func startRootLoad(_ path: String) {
        let generation = generation
        rootTimer?.cancel()
        if nodes.isEmpty { hideAll() }
        rootTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.generation == generation, self.requests[path] != nil else {
                return
            }
            if self.nodes.isEmpty { self.show(.loading) }
            try? await Task.sleep(for: .milliseconds(3700))
            guard !Task.isCancelled, self.generation == generation, self.requests[path] != nil else { return }
            self.log.info("files: listing of the root unfinished after 4 s; retrying")
            self.startRootLoad(path)
        }
        Task { await load(path, node: nil) }
    }

    // MARK: Loading

    /// Lists `folder` into `node`, or into the root when `node` is nil. Returns the root state it applied.
    @discardableResult
    private func load(_ folder: String, node: FileNode?) async -> FilesState? {
        let generation = generation
        nextRequest += 1
        let request = nextRequest
        requests[folder] = request
        let listing: FsListing
        do {
            listing = try await client.call(Methods.list, FsPathParams(path: folder), as: FsListing.self)
        } catch {
            if requests[folder] == request { requests[folder] = nil }
            log.warn("files: fs.list failed: \(error)")
            return nil
        }
        guard generation == self.generation, requests[folder] == request else { return nil }
        requests[folder] = nil
        if let node {
            apply(listing, to: node)
            return nil
        }
        return applyRoot(listing)
    }

    private func applyRoot(_ listing: FsListing) -> FilesState {
        guard let root else { return .noTerminal }
        rootTimer?.cancel()
        let state = FilesState(rawValue: listing.state) ?? .unreadable
        hiddenByExclude = listing.hiddenByExclude
        repoRoot = listing.repo?.root
        header.configure(path: root, branch: listing.repo?.branch)
        nodes =
            state == .ready
            ? FileNode.merge(listing.entries, into: nodes, parentPath: root, parentRelative: "", depth: 0) : []
        reloadKeepingSelection(nil)
        restoreExpansion(nodes)
        show(state)
        if let started = rootStarted {
            rootStarted = nil
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log.info("files: root listed state=\(state.rawValue) entries=\(listing.entries.count) ms=\(ms)")
        }
        missingPoll?.cancel()
        switch state {
        case .ready, .empty:
            watch(root)
        case .missing:
            // The tree recovers by itself when the folder comes back (UX §5.2).
            unwatch(root)
            missingPoll = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.root == root, self.state == .missing else { return }
                await self.load(root, node: nil)
            }
        default:
            break
        }
        return state
    }

    private func apply(_ listing: FsListing, to node: FileNode) {
        let children =
            listing.state == "ready"
            ? FileNode.merge(
                listing.entries, into: node.children, parentPath: node.path, parentRelative: node.relativePath,
                depth: node.depth + 1) : []
        node.children = children
        guard outline.row(forItem: node) >= 0 || nodes.contains(node) else { return }
        reloadKeepingSelection(node)
        restoreExpansion(children)
    }

    /// Re-expands the folders remembered for this root.
    private func restoreExpansion(_ items: [FileNode]) {
        guard let root, let expanded = expansion[root], !expanded.isEmpty else { return }
        isRestoringExpansion = true
        defer { isRestoringExpansion = false }
        for node in items where node.isFolder && expanded.contains(node.relativePath) {
            if !outline.isItemExpanded(node) { outline.expandItem(node) }
            if let children = node.children { restoreExpansion(children) }
        }
    }

    /// Reloads the root and every loaded, expanded folder in place (git changes, `explorer.refresh`).
    @discardableResult
    private func refreshAll() -> Task<FilesState?, Never>? {
        guard let root else { return nil }
        for node in loadedExpandedFolders(nodes) {
            watch(node.path)
            Task { await load(node.path, node: node) }
        }
        return Task { await load(root, node: nil) }
    }

    private func loadedExpandedFolders(_ items: [FileNode]) -> [FileNode] {
        items.flatMap { node -> [FileNode] in
            guard node.isFolder, outline.isItemExpanded(node), let children = node.children else { return [] }
            return [node] + loadedExpandedFolders(children)
        }
    }

    private func node(atPath path: String, in items: [FileNode]) -> FileNode? {
        for node in items {
            if node.path == path { return node }
            if node.isFolder, path.hasPrefix(node.path + "/"), let children = node.children {
                return self.node(atPath: path, in: children)
            }
        }
        return nil
    }

    private func retry() {
        guard let root else { return }
        rootStarted = .now
        startRootLoad(root)
    }

    // MARK: Events

    private func handle(_ event: Event) {
        switch event.payload {
        case .fsChanged(let change):
            guard let root else { return }
            if change.root == root {
                Task { await load(root, node: nil) }
            } else if let node = node(atPath: change.root, in: nodes), node.children != nil {
                Task { await load(node.path, node: node) }
            }
        case .gitChanged(let change):
            guard let root, root == change.root || root.hasPrefix(change.root + "/") || repoRoot == change.root
            else { return }
            refreshAll()
        default:
            break
        }
    }

    // MARK: Watches

    private func watch(_ folder: String) {
        guard !watched.contains(folder) else { return }
        watched.insert(folder)
        send(Methods.watch, folder)
    }

    private func unwatch(_ folder: String) {
        guard watched.remove(folder) != nil else { return }
        send(Methods.unwatch, folder)
    }

    private func send(_ method: String, _ path: String) {
        let client = client
        Task {
            do {
                _ = try await client.call(method, FsPathParams(path: path), as: EmptyObject.self)
            } catch {
                MapoLog.shared.debug("files: \(method) failed: \(error)")
            }
        }
    }

    // MARK: States

    private func hideAll() {
        scroll.isHidden = true
        stateView.isHidden = true
    }

    private func show(_ state: FilesState) {
        self.state = state
        if state == .ready {
            scroll.isHidden = false
            stateView.isHidden = true
            return
        }
        scroll.isHidden = true
        stateView.isHidden = false
        stateView.configure(state, path: root ?? "", hiddenByExclude: hiddenByExclude)
    }

    // MARK: explorer.* (PROTOCOL §6.5)

    /// `explorer.refresh`: reloads the tree and answers with the root and its state once the root is listed.
    public func explorerRefresh() async -> JSONValue {
        if let task = refreshAll() { _ = await task.value }
        return explorerResult()
    }

    /// `explorer.collapse`: collapses every folder and forgets this root's expansion.
    public func explorerCollapse() -> JSONValue {
        outline.collapseItem(nil, collapseChildren: true)
        if let root {
            expansion[root] = []
            for folder in watched where folder != root { unwatch(folder) }
        }
        return explorerResult()
    }

    private func explorerResult() -> JSONValue {
        .object(["path": root.map(JSONValue.string) ?? .null, "state": .string(state.rawValue)])
    }

    // MARK: Actions

    private func selectedNode() -> FileNode? {
        outline.item(atRow: outline.selectedRow) as? FileNode
    }

    @objc private func rowClicked() {
        outline.didSendClick = true
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        activate(node)
    }

    private func openSelection() {
        guard let node = selectedNode() else { return }
        activate(node)
    }

    /// A folder toggles; a file opens (UX §5.2).
    private func activate(_ node: FileNode) {
        if node.isFolder {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            open(node)
        }
    }

    /// `file.open` (T1.6): the file shows in the file pane and its editor takes focus (REQUIREMENTS §8.3). A
    /// rejection (the file went away, or can't be read) leaves the layout alone; it logs and beeps until
    /// `app.notice` shows the daemon's message.
    private func open(_ node: FileNode) {
        let client = client
        let path = node.path
        Task {
            do {
                let opened = try await client.openFile(path: path)
                FileEditors.focusWhenShown(opened.path)
            } catch {
                MapoLog.shared.info("files: open \(path): file.open failed: \(error)")
                NSSound.beep()
            }
        }
    }

    private func newShellTab(in folder: String) {
        let client = client
        Task {
            do {
                _ = try await client.call(
                    Method.tabCreate, TabCreateParams(kind: "shell", cwd: folder, placement: "focused", focus: true),
                    as: TabSummary.self)
            } catch {
                MapoLog.shared.warn("files: New Shell Tab Here failed: \(error)")
                NSSound.beep()
            }
        }
    }

    // MARK: Context menu (UX §5.2, R-FS-4)

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let action = MenuAction(handler)
            item.target = action
            item.representedObject = action
            menu.addItem(item)
        }
        let url = URL(fileURLWithPath: node.path)
        if node.isFolder {
            add("New Shell Tab Here") { [weak self] in self?.newShellTab(in: node.path) }
        } else {
            add("Open") { [weak self] in self?.open(node) }
            add("Open With Default App") { NSWorkspace.shared.open(url) }
        }
        menu.addItem(.separator())
        add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        menu.addItem(.separator())
        add("Copy Path") { Self.copy(node.path) }
        add("Copy Relative Path") { Self.copy(node.relativePath) }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: NSOutlineViewDataSource

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return nodes.count }
        return node.children?.count ?? 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return nodes[index] }
        return node.children?[index]
            ?? FileNode(name: "", path: "", relativePath: "", isFolder: false, depth: 0, git: nil)
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (
        any NSPasteboardWriting
    )? {
        guard let node = item as? FileNode else { return nil }
        return URL(fileURLWithPath: node.path) as NSURL
    }

    // MARK: NSOutlineViewDelegate

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        FilesMetrics.rowHeight
    }

    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? FileNode else { return nil }
        let rowView = FilesRowView()
        rowView.configure(node, expanded: outlineView.isItemExpanded(node))
        rowView.onPress = { [weak self, weak node] in
            guard let self, let node else { return }
            activate(node)
        }
        return rowView
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("files.cell")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? FilesCellView
            ?? {
                let cell = FilesCellView(frame: .zero)
                cell.identifier = identifier
                return cell
            }()
        cell.configure(node, expanded: outlineView.isItemExpanded(node))
        return cell
    }

    public func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? FilesRowView, let node = outlineView.item(atRow: row) as? FileNode else {
            return
        }
        rowView.configure(node, expanded: outlineView.isItemExpanded(node))
    }

    public func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any)
        -> String?
    {
        (item as? FileNode)?.name
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode, let root else { return }
        expansion[root, default: []].insert(node.relativePath)
        refreshRow(node)
        watch(node.path)
        if node.children == nil || !isRestoringExpansion {
            Task { await load(node.path, node: node) }
        }
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode, let root else { return }
        expansion[root]?.remove(node.relativePath)
        refreshRow(node)
        unwatch(node.path)
    }

    /// Reloads `item`'s children in place; the selected rows stay selected while their nodes still exist.
    private func reloadKeepingSelection(_ item: FileNode?) {
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
        outline.reloadItem(item, reloadChildren: true)
        let rows = IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if rows != outline.selectedRowIndexes { outline.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    private func rowElement(_ row: Int) -> FilesRowElement? {
        guard let node = outline.item(atRow: row) as? FileNode, let window = outline.window else { return nil }
        let element = rowElements[ObjectIdentifier(node)] ?? FilesRowElement()
        rowElements[ObjectIdentifier(node)] = element
        let frame = window.convertToScreen(outline.convert(outline.rect(ofRow: row), to: nil))
        element.configure(node, expanded: outline.isItemExpanded(node), frame: frame, parent: outline)
        element.onPress = { [weak self, weak node] in
            guard let self, let node else { return }
            activate(node)
        }
        return element
    }

    private func refreshRow(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        let expanded = outline.isItemExpanded(node)
        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FilesCellView)?.configure(
            node, expanded: expanded)
        (outline.rowView(atRow: row, makeIfNecessary: false) as? FilesRowView)?.configure(node, expanded: expanded)
    }
}

/// A context menu item's handler; the item keeps it alive through `representedObject`.
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}
