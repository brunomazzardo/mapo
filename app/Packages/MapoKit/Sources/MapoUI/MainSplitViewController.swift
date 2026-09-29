import AppKit

/// The window's three columns (UX §2, §2.2): the rail as the sidebar item and the inspector as the inspector
/// item, both of which give their content system Liquid Glass (UX §2.3), and the panes area as the content
/// item, over the window backdrop. The inspector is collapsed at first. Widths and collapsed
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

        // The backdrop is a plain subview under the three items, so the split view must lay out only the
        // items' views.
        splitView.arrangesAllSubviews = false
        for item in [railItem, panesItem, inspectorItem] { addSplitViewItem(item) }
        splitView.autosaveName = "split-\(instance)"
        installBackdrop()
        if Theme.forcesOpaqueGlass {
            for side in [rail.view, inspector.view] { Self.addOpaqueGlass(to: side) }
        }
    }

    /// The window backdrop (UX §2, §9.1) at the bottom of the content view, under the rail, the panes and
    /// the inspector, so it shows through the toolbar band, the pane gutters and the glass.
    private func installBackdrop() {
        let backdrop = BackdropView(frame: splitView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        splitView.addSubview(backdrop, positioned: .below, relativeTo: nil)
    }

    /// Reduce Transparency forced on by `[ui] reduce-transparency = "on"`: macOS only makes the system glass
    /// opaque for its own setting, so the rail and inspector get the `glassOpaque` fill (UX §9.4).
    private static func addOpaqueGlass(to view: NSView) {
        let fill = OpaqueGlassView(frame: view.bounds)
        fill.autoresizingMask = [.width, .height]
        view.addSubview(fill, positioned: .below, relativeTo: nil)
    }

    // While the window is occluded, AppKit's animated collapse never completes, so ⌃⌘S and ⌥⌘0 would do
    // nothing in a drive without pixels (ENGINEERING §4.6). Then the toggles flip the item directly.

    public override func toggleSidebar(_ sender: Any?) {
        guard isOccluded, let item = splitViewItems.first else { return super.toggleSidebar(sender) }
        item.isCollapsed.toggle()
    }

    public override func toggleInspector(_ sender: Any?) {
        guard isOccluded, let item = splitViewItems.last else { return super.toggleInspector(sender) }
        item.isCollapsed.toggle()
    }

    private var isOccluded: Bool {
        !(view.window?.occlusionState.contains(.visible) ?? true)
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
            // Only the split view's own dividers; pane gutters are splitter views further down the tree.
            .filter { $0.accessibilityRole() == .splitter && !($0 is NSView) }
            .sorted { $0.accessibilityFrame().minX < $1.accessibilityFrame().minX }
        let names = [AXID.windowDividerRail, AXID.windowDividerInspector]
        for (splitter, name) in zip(splitters, names) {
            splitter.setAccessibilityIdentifier(name)
            splitter.setAccessibilityLabel(name == AXID.windowDividerRail ? "Sidebar Divider" : "Inspector Divider")
        }
        return children
    }
}
