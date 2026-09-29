import AppKit
import MapoClient
import MapoProtocol
import MapoTerminal

/// What the panes area asks of the app.
public struct PaneAreaActions {
    public var newShellTab: () -> Void
    public var restartDaemon: () -> Void
    /// Runs a daemon command; a failure is logged and beeps.
    public var perform: (_ name: String, _ body: @escaping (MapoClient) async throws -> Void) -> Void
    /// Close Tab with the R-TAB-7 confirmation.
    public var closeTab: (_ tabId: String) -> Void
    /// `ui.visibility`, sent quietly.
    public var reportVisibility: (_ keyWindow: Bool, _ visibleTabIds: [String], _ focusedTabId: String?) -> Void

    public init(
        newShellTab: @escaping () -> Void, restartDaemon: @escaping () -> Void,
        perform: @escaping (_ name: String, _ body: @escaping (MapoClient) async throws -> Void) -> Void,
        closeTab: @escaping (_ tabId: String) -> Void,
        reportVisibility: @escaping (_ keyWindow: Bool, _ visibleTabIds: [String], _ focusedTabId: String?) -> Void
    ) {
        self.newShellTab = newShellTab
        self.restartDaemon = restartDaemon
        self.perform = perform
        self.closeTab = closeTab
        self.reportVisibility = reportVisibility
    }
}

/// The panes area (UX §2, §4): the active workspace's tiling layout, or a placeholder before there is one.
/// Each workspace has its own cached `WorkspacePanesView`; a switch hides one and shows the other without
/// rebuilding surfaces (PLAN T1.3). Terminals of tabs that aren't on screen are freed after 30 s by the
/// `SurfaceRegistry`. `app.banner` floats at the top while mapod is unreachable, and the window is never
/// blank (R-NF-3).
public final class PaneAreaViewController: NSViewController {
    private let store: AppStore
    private let registry: SurfaceRegistry
    private let actions: PaneAreaActions

    private let backdrop = BackdropView()
    private let panesHost = FlippedView()
    private let banner = BannerView()
    private let placeholder = PlaceholderView()
    private var containers: [String: WorkspacePanesView] = [:]
    private var shownContainer: WorkspacePanesView?

    /// The workspace, focused pane and its content that keyboard focus last followed.
    private var lastFocusKey: String?
    /// Set by user actions whose result should take keyboard focus (⌘T, ⌘D, ⇧⌘N, a pane's buttons), even
    /// from the rail; cleared once the focused pane changed and took focus.
    private var focusRequested = true
    private var focusRequestGeneration = 0
    private var firstResponderObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastVisibility: VisibilityReport?
    private var visibilityPending = false

    private struct VisibilityReport: Equatable {
        var keyWindow: Bool
        var visibleTabIds: [String]
        var focusedTabId: String?
    }

    public init(store: AppStore, registry: SurfaceRegistry, actions: PaneAreaActions) {
        self.store = store
        self.registry = registry
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneAreaViewController is built in code")
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 900))
        for view in [backdrop, panesHost, placeholder, banner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let top = root.safeAreaLayoutGuide.topAnchor
        // Panes sit 10 from the rail, the inspector and the window bottom, and 4 below the toolbar (UX §2.2).
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panesHost.topAnchor.constraint(equalTo: top, constant: 4),
            panesHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            panesHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            panesHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            placeholder.topAnchor.constraint(equalTo: panesHost.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: panesHost.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: panesHost.trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: panesHost.bottomAnchor),
            banner.topAnchor.constraint(equalTo: top, constant: 12),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
        ])
        banner.onRestart = actions.restartDaemon
        placeholder.onNewShellTab = actions.newShellTab
        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        observeContinuously(self) { $0.render() }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, firstResponderObservation == nil else { return }
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged() }
        }
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
            (NSApplication.didBecomeActiveNotification, nil), (NSApplication.didResignActiveNotification, nil),
        ]
        for (name, object) in names {
            notificationTokens.append(
                center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.render() }
                })
        }
    }

    // MARK: Focus

    /// Gives keyboard focus to the focused pane's content now (a rail click on a tab, UX §3.4).
    public func focusTerminal() {
        guard let container = shownContainer, let paneId = container.focusedPaneId,
            let card = container.card(for: paneId)
        else { return }
        card.focusContent()
    }

    /// The next change of focused pane or content comes from a person's command: move keyboard focus to it
    /// even if the rail or the inspector has it now.
    public func expectFocusChange() {
        focusRequested = true
        focusRequestGeneration += 1
        let generation = focusRequestGeneration
        // A command that changes nothing (focus at an edge) must not let a later background change steal focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, focusRequestGeneration == generation else { return }
            focusRequested = false
        }
    }

    /// Whether the focused pane is large enough to split in `direction` (`right` or `down`) and leave two
    /// panes of at least 200×120 (UX §4.2).
    public func canSplitFocusedPane(_ direction: String) -> Bool {
        guard let container = shownContainer, let paneId = container.focusedPaneId,
            let card = container.card(for: paneId)
        else { return true }
        let gutter = SplitContainerView.gutter
        let minimum = SplitContainerView.minimumPane
        if direction == "right" { return (card.frame.width - gutter) / 2 >= minimum.width }
        return (card.frame.height - gutter) / 2 >= minimum.height
    }

    /// A left mouse-down anywhere in the window: one inside a pane that isn't focused focuses it (UX §4.1).
    /// It comes from the window before AppKit routes it, so the first click into an inactive window counts.
    public func windowMouseDown(_ event: NSEvent) {
        guard let container = shownContainer, !container.isHidden,
            let paneId = container.paneId(at: event.locationInWindow), paneId != container.focusedPaneId
        else { return }
        expectFocusChange()
        actions.perform("pane.focus") { try await $0.focusPane(id: paneId) }
    }

    /// The pane whose content just took keyboard focus becomes the focused pane (UX §4.1).
    private func firstResponderChanged() {
        guard let view = view.window?.firstResponder as? NSView, let container = shownContainer,
            let paneId = container.paneId(containing: view), paneId != container.focusedPaneId
        else { return }
        actions.perform("pane.focus") { try await $0.focusPane(id: paneId) }
    }

    /// Moves keyboard focus into the focused pane when it changed, unless a person is working in the rail or
    /// the inspector. Status updates never get here: they change neither the pane nor its content (R-LAY-7).
    private func followFocus(in container: WorkspacePanesView, workspaceId: String) {
        guard let paneId = container.focusedPaneId, let card = container.card(for: paneId) else { return }
        let content = card.model?.tab?.id ?? (card.model?.content.filePath ?? "empty")
        let key = "\(workspaceId)|\(paneId)|\(content)"
        guard key != lastFocusKey else { return }
        // A pane whose tab isn't in the store yet has nothing to focus; try again on the next render.
        if card.model?.content.tabId != nil && card.model?.tab == nil { return }
        lastFocusKey = key
        let responder = view.window?.firstResponder
        let responderInPanes =
            responder == nil || responder === view.window
            || (responder as? NSView)?.isDescendant(of: view) == true
        guard focusRequested || responderInPanes else { return }
        focusRequested = false
        card.focusContent()
    }

    // MARK: Rendering

    private func render() {
        banner.update(connection: store.connection, restarting: store.isRestartingDaemon)
        registry.setDaemonReachable(store.isConnected)
        if store.hasSnapshot {
            closeSurfacesOfClosedTabs()
            dropContainersOfDeletedWorkspaces()
        }
        guard store.hasSnapshot else {
            show(container: nil)
            placeholder.show(
                .message(title: store.connection == .connecting ? "Connecting to mapod…" : "", detail: nil))
            return
        }
        guard let workspace = store.activeWorkspace else {
            show(container: nil)
            placeholder.show(.message(title: "Create a workspace to start.", detail: "New Workspace  ⇧⌘N"))
            scheduleVisibilityReport()
            return
        }
        placeholder.show(.none)
        let container = container(for: workspace.id)
        show(container: container)
        container.apply(store: store, registry: registry, isKeyWindow: isKeyWindow)
        registry.updateVisibility(visible: Set(container.shownTabIds))
        followFocus(in: container, workspaceId: workspace.id)
        scheduleVisibilityReport()
    }

    private var isKeyWindow: Bool {
        (view.window?.isKeyWindow ?? false) && NSApp.isActive
    }

    private func container(for workspaceId: String) -> WorkspacePanesView {
        if let container = containers[workspaceId] { return container }
        let container = WorkspacePanesView(
            workspaceId: workspaceId,
            actions: PaneCardActions(
                closePane: { [weak self] id in
                    self?.actions.perform("pane.close") { try await $0.closePane(id: id) }
                },
                newTab: { [weak self] id, kind in
                    self?.expectFocusChange()
                    self?.actions.perform("New Tab") { try await $0.newTab(inPane: id, kind: kind) }
                },
                stopTab: { [weak self] id in
                    self?.actions.perform("tab.stop") { try await $0.tabCommand("tab.stop", id: id) }
                },
                restartTab: { [weak self] id in
                    guard let self else { return }
                    let registry = registry
                    actions.perform("tab.restart") { client in
                        try await client.tabCommand("tab.restart", id: id)
                        // The old surface's `mapo attach` ended with the shell; a new one attaches.
                        registry.existingHost(for: id)?.reconnect()
                    }
                },
                closeTab: { [weak self] id in self?.actions.closeTab(id) }),
            onResize: { [weak self] split, ratios in
                self?.actions.perform("pane.resize") { try await $0.resizeSplit(id: split, ratios: ratios) }
            },
            onEqualize: { [weak self] split in
                self?.actions.perform("pane.equalize") { try await $0.equalizePanes(split: split) }
            })
        container.frame = panesHost.bounds
        container.autoresizingMask = [.width, .height]
        container.isHidden = true
        panesHost.addSubview(container)
        containers[workspaceId] = container
        return container
    }

    /// Shows one workspace's container and hides the others. Hidden containers keep their views.
    private func show(container: WorkspacePanesView?) {
        guard container !== shownContainer else { return }
        shownContainer?.isHidden = true
        container?.isHidden = false
        shownContainer = container
        if container == nil { registry.updateVisibility(visible: []) }
    }

    /// Stops surfaces whose tabs the daemon closed.
    private func closeSurfacesOfClosedTabs() {
        for tabId in registry.tabIds where store.tabs[tabId] == nil {
            registry.close(tabId)
        }
    }

    private func dropContainersOfDeletedWorkspaces() {
        for (id, container) in containers where store.workspace(id: id) == nil {
            if container === shownContainer { shownContainer = nil }
            container.removeFromSuperview()
            containers[id] = nil
        }
    }

    // MARK: ui.visibility

    /// Sends `ui.visibility` once per runloop turn when what the person sees changed (PROTOCOL §6.8).
    private func scheduleVisibilityReport() {
        guard !visibilityPending else { return }
        visibilityPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            visibilityPending = false
            guard store.isConnected else {
                lastVisibility = nil
                return
            }
            let container = store.activeWorkspace == nil ? nil : shownContainer
            let focusedTab = container?.focusedPaneId.flatMap { container?.card(for: $0)?.model?.tab?.id }
            let report = VisibilityReport(
                keyWindow: isKeyWindow, visibleTabIds: container?.shownTabIds ?? [], focusedTabId: focusedTab)
            guard report != lastVisibility else { return }
            lastVisibility = report
            actions.reportVisibility(report.keyWindow, report.visibleTabIds, report.focusedTabId)
        }
    }
}

/// A plain flipped container.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The window backdrop behind the panes (UX §9.1), a vertical gradient.
final class BackdropView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gradient)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BackdropView is built in code")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            gradient.colors = [Tokens.backdropBottom.cgColor, Tokens.backdropTop.cgColor]
        }
    }
}

/// The centered text of the panes area: connecting, no workspace, or the empty pane of UX §4.4.
final class PlaceholderView: NSView {
    enum Content: Equatable {
        case none
        case message(title: String, detail: String?)
        case emptyPane(paneId: String?)
    }

    var onNewShellTab: (() -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let button = NSButton(title: "New Shell Tab", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "⌘T")
    private let stack = NSStackView()
    private var content = Content.none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Tokens.textSecondary
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Tokens.textSecondary
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = Tokens.textSecondary
        button.bezelStyle = .push
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.tintProminence = .primary
        button.target = self
        button.action = #selector(newShellTab)
        let buttonRow = NSStackView(views: [button, hint])
        buttonRow.spacing = 8
        stack.setViews([title, buttonRow, detail], in: .center)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show(.none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlaceholderView is built in code")
    }

    func show(_ content: Content) {
        guard content != self.content || content == .none else { return }
        self.content = content
        switch content {
        case .none:
            isHidden = true
        case .message(let titleText, let detailText):
            isHidden = titleText.isEmpty
            title.stringValue = titleText
            detail.stringValue = detailText ?? ""
            detail.isHidden = detailText == nil
            button.superview?.isHidden = true
        case .emptyPane(let paneId):
            isHidden = false
            title.stringValue = "Empty pane"
            detail.stringValue = "Or choose a tab in the sidebar."
            detail.isHidden = false
            button.superview?.isHidden = false
            button.setAXIdentifier(AXID.paneEmptyNewShell(paneId))
        }
    }

    @objc private func newShellTab() {
        onNewShellTab?()
    }
}
