import AppKit
import MapoClient

/// What the rail asks of the app. Each action is a daemon command (AGENTS.md, non-negotiable 1).
public struct RailActions {
    public var activateWorkspace: (_ workspaceId: String) -> Void
    public var focusTab: (_ tabId: String) -> Void
    public var newWorkspace: () -> Void

    public init(
        activateWorkspace: @escaping (String) -> Void, focusTab: @escaping (String) -> Void,
        newWorkspace: @escaping () -> Void
    ) {
        self.activateWorkspace = activateWorkspace
        self.focusTab = focusTab
        self.newWorkspace = newWorkspace
    }
}

/// The basic S2 rail (UX §3, PLAN T0.7 step 7): 26 pt workspace rows, 24 pt tab rows for the active
/// workspace only, state dots and words. It watches the store and reloads only the rows that changed;
/// a change in which rows exist reloads the list.
public final class RailViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let store: AppStore
    private let actions: RailActions
    private let outline = RailOutlineView()
    private let scroll = NSScrollView()
    private var items: [RailItem] = []

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
        outline.setAccessibilityIdentifier(AXID.rail)
        outline.setAccessibilityLabel("Workspaces")

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

    public override func viewDidLayout() {
        super.viewDidLayout()
        outline.sizeLastColumnToFit()
    }

    // MARK: Rendering

    private func render() {
        let rows = RailModel.rows(store)
        if rows.map(\.key) != items.map(\.row.key) {
            let existing = Dictionary(items.map { ($0.row.key, $0) }, uniquingKeysWith: { first, _ in first })
            items = rows.map { row in
                let item = existing[row.key] ?? RailItem(row: row)
                item.row = row
                return item
            }
            outline.reloadData()
            outline.sizeLastColumnToFit()
            return
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
    }

    @objc private func rowClicked() {
        let index = outline.clickedRow
        guard items.indices.contains(index) else { return }
        activate(items[index].row)
    }

    private func activate(_ row: RailRow) {
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
