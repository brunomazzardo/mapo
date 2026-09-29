import AppKit
import MapoClient
import MapoProtocol
import MapoTerminal

/// One workspace's panes: renders its `Layout` as nested `SplitContainerView`s with `PaneCardView` leaves
/// (UX §4). Views are kept by node id, so a layout change re-parents existing cards and terminals instead of
/// rebuilding them. The panes area caches one per workspace and swaps them on a switch (PLAN T1.3).
final class WorkspacePanesView: NSView {
    let workspaceId: String
    private let actions: PaneCardActions
    private let onResize: (String, [Double]) -> Void
    private let onEqualize: (String) -> Void
    private var cards: [String: PaneCardView] = [:]
    private var splits: [String: SplitContainerView] = [:]
    private var rootView: NSView?

    /// Tabs shown in this workspace's panes, from the last `apply`.
    private(set) var shownTabIds: [String] = []
    /// The focused pane id and what it shows, from the last `apply`.
    private(set) var focusedPaneId: String?

    init(
        workspaceId: String, actions: PaneCardActions, onResize: @escaping (String, [Double]) -> Void,
        onEqualize: @escaping (String) -> Void
    ) {
        self.workspaceId = workspaceId
        self.actions = actions
        self.onResize = onResize
        self.onEqualize = onEqualize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspacePanesView is built in code")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        rootView?.frame = bounds
    }

    /// Renders the workspace's layout from the store. Terminal bodies come from `registry`.
    func apply(store: AppStore, registry: SurfaceRegistry, isKeyWindow: Bool) {
        let (rootNode, focused) = Self.layout(store: store, workspaceId: workspaceId)
        let paneCount = Self.paneCount(rootNode)
        let branch = store.workspace(id: workspaceId)?.branch
        var seenCards = Set<String>()
        var seenSplits = Set<String>()
        var shown: [String] = []

        func build(_ node: LayoutNode) -> NSView {
            switch node {
            case .pane(let id, let content, _):
                seenCards.insert(id)
                let card = cards[id] ?? PaneCardView(actions: actions)
                cards[id] = card
                var tab: TabSummary?
                var host: TerminalHostView?
                if let tabId = content.tabId, let summary = store.tabs[tabId] {
                    tab = summary
                    host = registry.host(for: tabId, tabName: summary.name)
                    shown.append(tabId)
                }
                let isFocused = id == focused
                card.update(
                    PaneCardModel(
                        paneId: id, content: content, tab: tab, branch: branch, isFocused: isFocused,
                        showsRing: paneCount > 1, isKeyWindow: isKeyWindow,
                        takesReturn: isFocused && tab == nil && !content.isFile),
                    host: host)
                return card
            case .split(let id, let axis, let ratios, let children):
                seenSplits.insert(id)
                let split = splits[id] ?? SplitContainerView(splitId: id)
                if splits[id] == nil {
                    split.onResize = onResize
                    split.onEqualize = onEqualize
                }
                splits[id] = split
                split.update(axis: axis, ratios: ratios, children: children.map(build))
                return split
            }
        }

        let root = build(rootNode)
        if root !== rootView {
            if let rootView, rootView.superview === self { rootView.removeFromSuperview() }
            addSubview(root)
            rootView = root
            root.frame = bounds
        }
        for (id, card) in cards where !seenCards.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        for (id, split) in splits where !seenSplits.contains(id) {
            split.removeFromSuperview()
            splits[id] = nil
        }
        shownTabIds = shown
        focusedPaneId = focused
    }

    func card(for paneId: String) -> PaneCardView? {
        cards[paneId]
    }

    /// The pane under a point in window coordinates; gutters belong to no pane.
    func paneId(at windowPoint: NSPoint) -> String? {
        cards.first { _, card in
            card.window != nil && card.bounds.contains(card.convert(windowPoint, from: nil))
        }?.key
    }

    /// The pane whose card holds `view`, such as the first responder.
    func paneId(containing view: NSView) -> String? {
        cards.first { $0.value.contains(view) }?.key
    }

    /// The workspace's layout tree and focused pane; before the daemon's layout arrives, one pane made from
    /// the workspace's active tab.
    private static func layout(store: AppStore, workspaceId: String) -> (LayoutNode, String?) {
        if let layout = store.layouts[workspaceId] {
            return (layout.root, layout.focusedPane?.id)
        }
        let pane = store.focusedPane(inWorkspace: workspaceId)
        return (.pane(id: pane.id ?? "", content: pane.content, recentFiles: []), pane.id ?? "")
    }

    private static func paneCount(_ node: LayoutNode) -> Int {
        switch node {
        case .pane: 1
        case .split(_, _, _, let children): children.reduce(0) { $0 + paneCount($1) }
        }
    }
}
