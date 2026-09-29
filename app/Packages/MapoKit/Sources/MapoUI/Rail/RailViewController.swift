import AppKit
import MapoClient
import MapoProtocol

/// What the rail asks of the app. Each action is a daemon command (AGENTS.md, non-negotiable 1).
public struct RailActions {
    public var activateWorkspace: (_ workspaceId: String) -> Void
    public var focusTab: (_ tabId: String) -> Void
    public var newWorkspace: () -> Void
    /// New Tab in Folder… and Set Agent Command… for a workspace row (UX §3.5).
    public var newTabInFolder: (_ workspaceId: String) -> Void
    public var setAgentCommand: (_ workspaceId: String) -> Void

    public init(
        activateWorkspace: @escaping (String) -> Void, focusTab: @escaping (String) -> Void,
        newWorkspace: @escaping () -> Void, newTabInFolder: @escaping (String) -> Void,
        setAgentCommand: @escaping (String) -> Void
    ) {
        self.activateWorkspace = activateWorkspace
        self.focusTab = focusTab
        self.newWorkspace = newWorkspace
        self.newTabInFolder = newTabInFolder
        self.setAgentCommand = setAgentCommand
    }
}

/// The S2 rail (UX §3, PLAN T1.1): 26 pt workspace rows, 24 pt tab rows for the active workspace only,
/// state dots and words, the inline branch, hold-⌘ hints, context menus, inline rename and drag reorder.
/// It watches the store and repaints only the rows that changed; rows that appear or go are inserted and
/// removed in place, so background updates never scroll or move focus (UX §3.7).
public final class RailViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate
{
    let store: AppStore
    let actions: RailActions
    let outline = RailOutlineView()
    private let scroll = NSScrollView()
    var items: [RailItem] = []
    /// The open rename field, if any.
    var renameField: RailRenameField?
    /// A row to scroll into view once it exists, after a reorder (UX §3.7 rule 5).
    var revealKey: String?
    private var hintMonitor: Any?
    private var hintTimer: Timer?
    private var resignObserver: NSObjectProtocol?

    /// The daemon connection behind the store, for the rail's own commands.
    var client: MapoClient? { MapoClient.owner(of: store) }

    public init(store: AppStore, actions: RailActions) {
        self.store = store
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RailViewController is built in code")
    }

    public override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rail"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowSizeStyle = .custom
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.setAccessibilityIdentifier(AXID.rail)
        outline.setAccessibilityLabel("Workspaces")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.registerForDraggedTypes([.railRow])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = true
        scroll.contentView.automaticallyAdjustsContentInsets = true

        let root = NSView()
        root.prefersCompactControlSizeMetrics = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        root.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        observeContinuously(self) { $0.render() }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        installHintMonitor()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        removeHintMonitor()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        outline.sizeLastColumnToFit()
    }

    // MARK: Rendering

    private func render() {
        let rows = RailModel.rows(store)
        let newKeys = rows.map(\.key)
        if items.map(\.row.key) != newKeys {
            applyStructure(rows)
        }
        for (index, row) in rows.enumerated() where items[index].row != row {
            let heightChanged = items[index].row.height != row.height
            items[index].row = row
            if let rowView = outline.rowView(atRow: index, makeIfNecessary: false) as? RailRowView {
                rowView.configure(row)
            }
            if let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? RailCellView {
                cell.configure(row)
            }
            if heightChanged { outline.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index)) }
        }
        if let renameField, !newKeys.contains(renameField.rowKey) { endRename() }
        if let key = revealKey, let index = newKeys.firstIndex(of: key) {
            revealKey = nil
            outline.scrollRowToVisible(index)
        }
    }

    /// Removes and inserts only the rows that went or came, keeping the scroll offset (UX §3.7 rules 2 and
    /// 4). A reorder arrives as a removal and an insertion of the same key. Rows that stay keep their stale
    /// contents here; `render` repaints them next.
    private func applyStructure(_ rows: [RailRow]) {
        let existing = Dictionary(items.map { ($0.row.key, $0) }, uniquingKeysWith: { first, _ in first })
        let difference = rows.map(\.key).difference(from: items.map(\.row.key))
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        outline.beginUpdates()
        for change in difference.removals.reversed() {
            guard case .remove(let offset, _, _) = change else { continue }
            items.remove(at: offset)
            outline.removeItems(at: IndexSet(integer: offset), inParent: nil, withAnimation: [])
        }
        for change in difference.insertions {
            guard case .insert(let offset, let key, _) = change else { continue }
            // A moved row keeps its item, so the table keeps its identity.
            let item = existing[key] ?? RailItem(row: rows[offset])
            items.insert(item, at: offset)
            outline.insertItems(at: IndexSet(integer: offset), inParent: nil, withAnimation: [])
        }
        outline.endUpdates()
        // Deleting rows keeps the offset unless the list got too short for it (UX §3.7 rule 4).
        let maxY = max(-clip.contentInsets.top, outline.frame.height - clip.bounds.height + clip.contentInsets.bottom)
        let target = NSPoint(x: origin.x, y: min(origin.y, maxY))
        if clip.bounds.origin != target {
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
        }
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        let index = outline.clickedRow
        guard items.indices.contains(index) else { return }
        hideHints()
        let row = items[index].row
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true, row.isTab, let id = row.modelId,
            store.tabs[id]?.visible == false
        {
            // ⌥-click shows the tab to the right (UX §3.4).
            run("Show to the Right") { try await $0.showTab(id: id, direction: "right") }
            return
        }
        activate(row)
    }

    @objc private func rowDoubleClicked() {
        let index = outline.clickedRow
        guard items.indices.contains(index), items[index].row.isInteractive else { return }
        let key = items[index].row.key
        // The first click's `tab.focus` moves focus into the terminal once the daemon answers; open the
        // field after that, so it keeps focus.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.beginRename(key: key)
        }
    }

    func activate(_ row: RailRow) {
        guard let id = row.modelId else { return }
        switch row.kind {
        case .workspace(_, let active):
            // Clicking the active workspace does nothing (UX §3.4).
            if !active { actions.activateWorkspace(id) }
        case .tab:
            actions.focusTab(id)
        default:
            break
        }
    }

    /// Runs a daemon command. A failure is logged and beeps.
    func run(_ name: String, _ body: @escaping (MapoClient) async throws -> Void) {
        guard let client else {
            NSSound.beep()
            return
        }
        Task {
            do {
                try await body(client)
            } catch {
                MapoLog.shared.warn("\(name) failed: \(error)")
                NSSound.beep()
            }
        }
    }

    // MARK: Rename (UX §3.4)

    /// Rename Tab (⌥⌘R) and Rename Workspace from the menus and the palette: the row's inline field.
    public func beginRename(tabId: String) {
        beginRename(key: "tab:\(tabId)")
    }

    public func beginRename(workspaceId: String) {
        beginRename(key: "workspace:\(workspaceId)")
    }

    /// Turns the row's name into the `rail.rename` field.
    func beginRename(key: String) {
        guard let index = items.firstIndex(where: { $0.row.key == key }), let id = items[index].row.modelId else {
            return
        }
        let row = items[index].row
        let current: String
        switch row.kind {
        case .workspace: current = store.workspace(id: id)?.name ?? row.text
        case .tab: current = store.tabs[id]?.name ?? row.text
        default: return
        }
        endRename()
        outline.scrollRowToVisible(index)
        guard let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? RailCellView else { return }
        let field = RailRenameField(rowKey: key, text: current, font: cell.nameFont)
        let frame = cell.nameEditingFrame
        field.frame = NSRect(x: frame.minX - 3, y: frame.minY - 2, width: frame.width + 6, height: frame.height + 4)
        field.validate = { [weak self] name in self?.renameProblem(name, rowKey: key) }
        field.onCancel = { [weak self] in self?.endRename() }
        field.onCommit = { [weak self, weak field] name in
            guard let self, let client else { return }
            Task {
                do {
                    if row.isWorkspace {
                        try await client.renameWorkspace(id: id, name: name)
                    } else {
                        try await client.renameTab(id: id, name: name)
                    }
                    if let field, self.renameField === field { self.endRename() }
                } catch {
                    // The daemon still rejected it: keep the field open with its message.
                    field?.reject((error as? RPCError)?.message ?? "\(error)")
                }
            }
        }
        cell.addSubview(field)
        renameField = field
        field.begin()
    }

    /// Closes the field, if open, and gives focus back to the rail when the field had it.
    func endRename() {
        guard let field = renameField else { return }
        renameField = nil
        let hadFocus = field.currentEditor() != nil
        field.removeFromSuperview()
        if hadFocus { view.window?.makeFirstResponder(outline) }
    }

    /// Validation while typing (PA-28): an empty name, or a name already used among the row's siblings.
    private func renameProblem(_ name: String, rowKey: String) -> String? {
        guard let row = items.first(where: { $0.row.key == rowKey })?.row, let id = row.modelId else { return nil }
        if name.isEmpty { return "A name can't be empty." }
        if row.isWorkspace {
            if store.workspaces.contains(where: { $0.id != id && $0.name == name }) {
                return "A workspace named \"\(name)\" already exists."
            }
        } else if let workspaceId = row.workspaceId,
            store.tabs(inWorkspace: workspaceId).contains(where: { $0.id != id && $0.name == name })
        {
            return "This workspace already has a tab named \"\(name)\"."
        }
        return nil
    }

    // MARK: Hold-⌘ hints (UX §3.3)

    private func installHintMonitor() {
        guard hintMonitor == nil else { return }
        hintMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { [weak self] event in
            self?.handleHintEvent(event)
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, window === self.view.window else { return }
                self.hideHints()
            }
        }
    }

    private func removeHintMonitor() {
        if let hintMonitor { NSEvent.removeMonitor(hintMonitor) }
        hintMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        hideHints()
    }

    /// ⌘ alone, held 400 ms in this window, shows the hints; anything else hides them. The monitor never
    /// consumes the event.
    func handleHintEvent(_ event: NSEvent) {
        guard event.type == .flagsChanged, event.window === view.window else {
            hideHints()
            return
        }
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
        guard held == .command else {
            hideHints()
            return
        }
        guard hintTimer == nil, !RailHints.shared.visible else { return }
        hintTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hintTimer = nil
                RailHints.shared.visible = true
            }
        }
    }

    func hideHints() {
        hintTimer?.invalidate()
        hintTimer = nil
        if RailHints.shared.visible { RailHints.shared.visible = false }
    }

    // MARK: NSOutlineViewDataSource

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    // MARK: NSOutlineViewDelegate

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? RailItem).map { CGFloat($0.row.height) } ?? 24
    }

    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let item = item as? RailItem else { return nil }
        let rowView = RailRowView()
        rowView.configure(item.row)
        rowView.onPress = { [weak self, weak item] in
            guard let self, let item else { return }
            activate(item.row)
        }
        return rowView
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? RailItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("rail.cell")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? RailCellView
            ?? {
                let cell = RailCellView(frame: .zero)
                cell.identifier = identifier
                return cell
            }()
        cell.onButton = actions.newWorkspace
        cell.configure(item.row)
        return cell
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        false
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }
}

/// The rail's outline. Its accessibility children are the `RailRowView`s, which carry the identifiers, labels
/// and states (UX §3.8); AppKit's default `NSOutlineRow` proxies would hide them from `ui.tree`.
final class RailOutlineView: NSOutlineView {
    private var rowViews: [NSTableRowView] {
        (0..<numberOfRows).compactMap { rowView(atRow: $0, makeIfNecessary: true) }
    }

    override func accessibilityChildren() -> [Any]? {
        rowViews
    }
}

/// An outline item. Items keep their identity across renders so the table can reuse row views.
final class RailItem: NSObject {
    var row: RailRow

    init(row: RailRow) {
        self.row = row
    }
}
