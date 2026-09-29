import AppKit

/// The window's three columns (UX §2, §2.2): the rail as the sidebar item, which gives it Liquid Glass,
/// the panes area as the content item, and the inspector item, collapsed at first. Widths and collapsed
/// states autosave per instance as `split-<instance>`.
public final class MainSplitViewController: NSSplitViewController {
    private let rail: NSViewController
    private let panes: NSViewController
    private let inspector: NSViewController
    private let instance: String

    public init(rail: NSViewController, panes: NSViewController, inspector: NSViewController, instance: String) {
        self.rail = rail
        self.panes = panes
        self.inspector = inspector
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
        let split = MainSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainSplitViewController is built in code")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let railItem = NSSplitViewItem(sidebarWithViewController: rail)
        railItem.minimumThickness = 220
        railItem.maximumThickness = 400
        railItem.canCollapseFromWindowResize = true

        let panesItem = NSSplitViewItem(viewController: panes)
        panesItem.minimumThickness = 400

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 520
        inspectorItem.canCollapseFromWindowResize = true
        inspectorItem.isCollapsed = true

        for item in [railItem, panesItem, inspectorItem] { addSplitViewItem(item) }
        splitView.autosaveName = "split-\(instance)"
    }
}

/// The window's split view. Its dividers are `splitter` elements in `ui.tree`, which AppKit vends without
/// identifiers; this names them `window.divider:rail` and `window.divider:inspector` (UX §2.4).
final class MainSplitView: NSSplitView {
    override func accessibilityChildren() -> [Any]? {
        guard let children = super.accessibilityChildren() else { return nil }
        let splitters =
            children
            .compactMap { $0 as? NSObject & NSAccessibilityProtocol }
            .filter { $0.accessibilityRole() == .splitter }
            .sorted { $0.accessibilityFrame().minX < $1.accessibilityFrame().minX }
        let names = [AXID.windowDividerRail, AXID.windowDividerInspector]
        for (splitter, name) in zip(splitters, names) {
            splitter.setAccessibilityIdentifier(name)
            splitter.setAccessibilityLabel(name == AXID.windowDividerRail ? "Sidebar Divider" : "Inspector Divider")
        }
        return children
    }
}
