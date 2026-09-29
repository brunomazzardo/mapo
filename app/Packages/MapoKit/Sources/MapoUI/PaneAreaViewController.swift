import AppKit
import MapoClient
import MapoProtocol
import MapoTerminal

/// What the panes area asks of the app.
public struct PaneAreaActions {
    public var newShellTab: () -> Void
    public var restartDaemon: () -> Void

    public init(newShellTab: @escaping () -> Void, restartDaemon: @escaping () -> Void) {
        self.newShellTab = newShellTab
        self.restartDaemon = restartDaemon
    }
}

/// The panes area (UX §2, §4). In M0 it shows the active workspace's single pane: the focused tab's
/// terminal from the `SurfaceRegistry`, or an empty state. `app.banner` floats at its top while mapod is
/// unreachable, and the window is never blank (R-NF-3).
public final class PaneAreaViewController: NSViewController {
    private let store: AppStore
    private let registry: SurfaceRegistry
    private let actions: PaneAreaActions

    private let backdrop = BackdropView()
    private let card = PaneCardView()
    private let banner = BannerView()
    private let placeholder = PlaceholderView()
    private var shownHost: TerminalHostView?

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
        for view in [backdrop, card, placeholder, banner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let top = root.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.topAnchor.constraint(equalTo: top, constant: 4),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            placeholder.topAnchor.constraint(equalTo: card.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: card.bottomAnchor),
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

    /// Gives keyboard focus to the shown terminal, after a rail click on a tab (UX §3.4).
    public func focusTerminal() {
        shownHost?.focus()
    }

    private func render() {
        banner.update(connection: store.connection, restarting: store.isRestartingDaemon)
        registry.setDaemonReachable(store.isConnected)
        if store.hasSnapshot { closeSurfacesOfClosedTabs() }

        guard store.hasSnapshot else {
            show(host: nil)
            card.isHidden = true
            placeholder.show(
                .message(title: store.connection == .connecting ? "Connecting to mapod…" : "", detail: nil))
            return
        }
        guard let workspace = store.activeWorkspace else {
            show(host: nil)
            card.isHidden = true
            placeholder.show(.message(title: "Create a workspace to start.", detail: "New Workspace  ⇧⌘N"))
            return
        }
        card.isHidden = false
        let pane = store.focusedPane(inWorkspace: workspace.id)
        card.setAccessibilityIdentifier(pane.id.map(AXID.pane))
        if let tabId = pane.content.tabId, let tab = store.tabs[tabId] {
            placeholder.show(.none)
            show(host: registry.host(for: tab.id, tabName: tab.name))
            card.setAccessibilityLabel(tab.name)
            return
        }
        show(host: nil)
        switch pane.content {
        case .file(let path):
            showFilePlaceholder(path)
        case .diff(let ref):
            showFilePlaceholder(ref.path)
        case .tab, .empty:
            placeholder.show(.emptyPane(paneId: pane.id))
            card.setAccessibilityLabel("Empty pane")
        }
    }

    private func showFilePlaceholder(_ path: String) {
        placeholder.show(.message(title: (path as NSString).lastPathComponent, detail: "Files open in M1."))
        card.setAccessibilityLabel(path)
    }

    private func show(host: TerminalHostView?) {
        guard host !== shownHost else { return }
        if let shownHost {
            shownHost.setVisible(false)
            shownHost.removeFromSuperview()
        }
        shownHost = host
        guard let host else { return }
        host.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            host.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            host.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            host.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        host.setVisible(true)
        // A newly shown tab takes focus: ⌘T, ⇧⌘N and rail clicks all end in its terminal.
        host.focus()
    }

    /// Stops surfaces whose tabs the daemon closed.
    private func closeSurfacesOfClosedTabs() {
        for tabId in registry.tabIds where store.tabs[tabId] == nil {
            if registry.existingHost(for: tabId) === shownHost { show(host: nil) }
            registry.close(tabId)
        }
    }
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

/// A pane card: `pane` fill, radius 12, a 1 pt hairline, clipped content (UX §4.1).
final class PaneCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneCardView is built in code")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Tokens.pane.cgColor
            layer?.borderColor = Tokens.paneHairline.cgColor
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
            button.setAXIdentifier(paneId.map(AXID.paneEmptyNewShell))
        }
    }

    @objc private func newShellTab() {
        onNewShellTab?()
    }
}
