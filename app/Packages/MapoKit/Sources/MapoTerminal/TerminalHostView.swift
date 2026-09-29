import AppKit

/// Whether a surface's `mapo attach` is alive.
nonisolated public enum TerminalConnection: Equatable, Sendable {
    case connected
    /// The child exited: `mapo attach` gave up (exit 2), or it failed some other way.
    case disconnected(exitCode: Int32?)
}

/// A tab name's identifiers: the surface (`pane.terminal:<tabName>`) and its Reconnect button
/// (`pane.reconnect:<tabName>`).
public typealias TerminalIdentifiers = (_ tabName: String) -> (terminal: String, reconnect: String)

/// The body of a terminal pane: one tab's current surface plus the "Disconnected" scrim (UX §4.3).
///
/// This view outlives its surfaces. Reconnect replaces the surface, which replays from the daemon; the
/// pane keeps hosting the same `TerminalHostView`. A surface never closes its pane by itself: when the
/// child exits the scrim shows, and closing is the tab's business (`SurfaceRegistry.close`).
///
/// Accessibility: the surface view is the `pane.terminal:<tabName>` element, labeled with the title and
/// the connection state; the scrim's button is `pane.reconnect:<tabName>`.
public final class TerminalHostView: NSView {
    public let tabId: String
    public var tabName: String {
        didSet { updateAccessibility() }
    }
    public private(set) var surface: any TerminalSurface
    /// The title the program set, or nil before it sets one.
    public private(set) var title: String?
    public private(set) var connection: TerminalConnection = .connected
    /// False while the control connection to mapod is down; the scrim's button waits (UX §4.3).
    public var isDaemonReachable = true {
        didSet { scrim.setWaiting(!isDaemonReachable) }
    }

    public var onTitle: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onConnectionChange: ((TerminalConnection) -> Void)?

    private let makeSurface: () -> any TerminalSurface
    private let identifiers: TerminalIdentifiers
    private let scrim = DisconnectedScrim()
    private var isVisible = true
    private var refocusAfterMove = false

    /// - Parameters:
    ///   - identifiers: the surface's and the Reconnect button's identifiers for a tab name, from MapoUI's
    ///     `AXID`, the only place identifier strings are built (ENGINEERING §4.2).
    ///   - makeSurface: builds a fresh surface for this tab; called now and on every reconnect.
    public init(
        tabId: String, tabName: String, identifiers: @escaping TerminalIdentifiers,
        makeSurface: @escaping () -> any TerminalSurface
    ) {
        self.tabId = tabId
        self.tabName = tabName
        self.identifiers = identifiers
        self.makeSurface = makeSurface
        self.surface = makeSurface()
        super.init(frame: .zero)
        scrim.isHidden = true
        scrim.onReconnect = { [weak self] in self?.reconnect() }
        addSubview(scrim)
        install(surface)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TerminalHostView is built in code")
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        surface.view.frame = bounds
        scrim.frame = bounds
    }

    // A pane move or zoom takes the view out of the window and puts it back; keep focus across that.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let window, let responder = window.firstResponder as? NSView,
            responder.isDescendant(of: self)
        {
            refocusAfterMove = true
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, refocusAfterMove else { return }
        refocusAfterMove = false
        if connection == .connected { surface.focus() } else { window?.makeFirstResponder(scrim.button) }
    }

    // MARK: Pane API

    public func focus() {
        surface.focus()
    }

    public func setVisible(_ visible: Bool) {
        isVisible = visible
        surface.setVisible(visible)
    }

    /// Builds a new surface, which attaches and replays. Keeps focus if the old surface had it.
    public func reconnect() {
        guard isDaemonReachable else { return }
        let hadFocus = window.map { $0.firstResponder === surface.view } ?? false
        teardown(surface)
        surface = makeSurface()
        install(surface)
        setConnection(.connected)
        hideScrim()
        if hadFocus || window?.firstResponder === scrim.button { surface.focus() }
    }

    /// Stops the surface for good; call when the tab closes.
    public func close() {
        teardown(surface)
    }

    // MARK: Internals

    private func install(_ surface: any TerminalSurface) {
        let view = surface.view
        view.frame = bounds
        addSubview(view, positioned: .below, relativeTo: scrim)
        surface.setVisible(isVisible)
        surface.onTitle = { [weak self, weak surface] title in
            guard let self, surface === self.surface else { return }
            self.title = title
            self.updateAccessibility()
            self.onTitle?(title)
        }
        surface.onBell = { [weak self, weak surface] in
            guard let self, surface === self.surface else { return }
            self.onBell?()
        }
        surface.onExit = { [weak self, weak surface] code in
            guard let self, surface === self.surface else { return }
            self.setConnection(.disconnected(exitCode: code))
            self.showScrim()
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textArea)
        updateAccessibility()
    }

    private func teardown(_ surface: any TerminalSurface) {
        surface.onTitle = nil
        surface.onBell = nil
        surface.onExit = nil
        surface.close()
        surface.view.removeFromSuperview()
    }

    private func setConnection(_ connection: TerminalConnection) {
        guard connection != self.connection else { return }
        self.connection = connection
        updateAccessibility()
        onConnectionChange?(connection)
    }

    private func updateAccessibility() {
        let view = surface.view
        let ids = identifiers(tabName)
        view.setAccessibilityIdentifier(ids.terminal)
        let state = connection == .connected ? "connected" : "disconnected"
        view.setAccessibilityLabel("\(title ?? tabName), \(state)")
        // AppKit exposes the button's cell as its accessibility element, so the cell needs the identifier too.
        scrim.button.setAccessibilityIdentifier(ids.reconnect)
        scrim.button.cell?.setAccessibilityIdentifier(ids.reconnect)
        scrim.button.setAccessibilityLabel("Reconnect \(tabName)")
    }

    private func showScrim() {
        let hadFocus = window?.firstResponder === surface.view
        scrim.alphaValue = 0
        scrim.isHidden = false
        fade(scrim, to: 1)
        // Keys typed into a dead surface go nowhere; hand focus to the button instead.
        if hadFocus { window?.makeFirstResponder(scrim.button) }
        NSAccessibility.post(
            element: scrim, notification: .announcementRequested,
            userInfo: [.announcement: "Disconnected", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func hideScrim() {
        scrim.isHidden = true
    }

    private func fade(_ view: NSView, to alpha: CGFloat) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            view.animator().alphaValue = alpha
        }
    }
}

/// UX §4.3: a `pane` scrim at 80% with "Disconnected", an explanation, and [Reconnect].
private final class DisconnectedScrim: NSView {
    let button = NSButton(title: "Reconnect", target: nil, action: nil)
    var onReconnect: (() -> Void)?

    private let heading = NSTextField(labelWithString: "Disconnected")
    private let message = NSTextField(
        wrappingLabelWithString: "This terminal lost its connection to mapod. The tab keeps running while mapod is up.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        message.font = .systemFont(ofSize: 12)
        message.alignment = .center
        message.preferredMaxLayoutWidth = 320
        button.bezelStyle = .push
        button.controlSize = .regular
        // Primary without a Return key equivalent, which would steal Return from the other panes.
        button.tintProminence = .primary
        button.target = self
        button.action = #selector(reconnect)
        let stack = NSStackView(views: [heading, message, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DisconnectedScrim is built in code")
    }

    func setWaiting(_ waiting: Bool) {
        button.isEnabled = !waiting
        button.title = waiting ? "Waiting for mapod…" : "Reconnect"
    }

    @objc private func reconnect() {
        onReconnect?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = TerminalTheme.rgb(dark ? 0x1D1F25 : 0xFFFFFF, alpha: 0.8).cgColor
        heading.textColor = TerminalTheme.rgb(dark ? 0xF2F3F6 : 0x16181D)
        message.textColor = TerminalTheme.rgb(dark ? 0x9EA3AE : 0x5E6470)
        button.bezelColor = TerminalTheme.rgb(dark ? 0x4A70D6 : 0x2F63D0)
    }

    // The scrim swallows clicks so they don't reach the dead terminal under it.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
