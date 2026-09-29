import AppKit
import MapoEditor
import MapoProtocol
import MapoTerminal

/// What a pane card asks of the app. Every action names its own pane or tab, never "the focused one"
/// (REQUIREMENTS §8.7).
struct PaneCardActions {
    var closePane: (_ paneId: String) -> Void
    var newTab: (_ paneId: String, _ kind: String) -> Void
    var stopTab: (_ tabId: String) -> Void
    var restartTab: (_ tabId: String) -> Void
    var closeTab: (_ tabId: String) -> Void
    /// `file.open` from the recent-files pull-down (UX §6.1).
    var openFile: (_ path: String) -> Void
    /// Clear Recent Files (`pane.clearRecent`).
    var clearRecentFiles: (_ paneId: String) -> Void
}

/// What a card shows.
struct PaneCardModel: Equatable {
    var paneId: String
    var content: PaneContent
    var tab: TabSummary?
    var branch: String?
    var isFocused: Bool
    /// False when the workspace has a single pane, which shows no ring (UX §4.1).
    var showsRing: Bool
    var isKeyWindow: Bool
    /// The empty pane that Return acts on.
    var takesReturn: Bool
    /// A file pane's recent files, newest first.
    var recentFiles: [String] = []
}

/// A pane (UX §4.1): an opaque card, radius 12, 1 pt hairline, clipped content, with the header, the
/// body (a terminal, the empty pane or a file placeholder) and the exit bar of a stopped shell. The focused
/// pane gets a 1.5 pt `accent` ring outside its edge and a shadow; the ring drops to 35% while the window
/// isn't key. Clicking anywhere in the pane focuses it (the panes area sees the click first).
final class PaneCardView: NSView {
    private(set) var model: PaneCardModel?
    private(set) weak var host: TerminalHostView?
    /// The file pane's editor (T1.6).
    private(set) weak var editor: FileEditorView?
    private let actions: PaneCardActions

    private let ring = CALayer()
    private let clip = FlippedView()
    private let header = PaneHeaderView()
    private let body = FlippedView()
    private let empty = EmptyPaneView()
    private let fileLabel = NSTextField(labelWithString: "")
    private let exitBar = ExitBarView()

    init(actions: PaneCardActions) {
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.cornerCurve = .continuous
        ring.isHidden = true
        layer?.addSublayer(ring)

        clip.wantsLayer = true
        clip.layer?.cornerRadius = Theme.Radius.pane
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        addSubview(clip)
        for view in [header, body, exitBar] as [NSView] { clip.addSubview(view) }
        body.addSubview(empty)
        fileLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fileLabel.textColor = Tokens.textSecondary
        fileLabel.alignment = .center
        body.addSubview(fileLabel)

        header.onClose = { [weak self] in self?.close() }
        header.onOpenRecent = { path in actions.openFile(path) }
        header.onClearRecent = { [weak self] in self?.model.map { actions.clearRecentFiles($0.paneId) } }
        header.onStop = { [weak self] in self?.model?.tab.map { actions.stopTab($0.id) } }
        empty.onNewTab = { [weak self] kind in self?.model.map { actions.newTab($0.paneId, kind) } }
        exitBar.onRestart = { [weak self] in self?.model?.tab.map { actions.restartTab($0.id) } }
        exitBar.onCloseTab = { [weak self] in self?.model?.tab.map { actions.closeTab($0.id) } }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneCardView is built in code")
    }

    override var isFlipped: Bool { true }

    /// Shows `model`, hosting `host` in the body when the pane shows a terminal, or `editor` when it shows a
    /// file.
    func update(_ model: PaneCardModel, host: TerminalHostView?, editor: FileEditorView? = nil) {
        if editor !== self.editor {
            if let old = self.editor {
                old.onStateChange = nil
                old.onCloseRequest = nil
                if old.superview === body { old.removeFromSuperview() }
                FileEditors.registry.release(old.path)
            }
            self.editor = editor
            if let editor {
                body.addSubview(editor, positioned: .below, relativeTo: empty)
                editor.onStateChange = { [weak self, weak editor] in
                    guard let self, let editor, editor === self.editor else { return }
                    header.updateFile(dirty: editor.isDirty, meta: editor.headerMeta)
                }
                editor.onCloseRequest = { [weak self] in
                    guard let self, let paneId = self.model?.paneId else { return }
                    actions.closePane(paneId)
                }
            }
            needsLayout = true
        } else if let editor, editor.superview !== body {
            // Another workspace's card showed the same file meanwhile; take it back.
            body.addSubview(editor, positioned: .below, relativeTo: empty)
            needsLayout = true
        }
        if host !== self.host {
            // The host may have moved to another card already in this pass; only take ours out.
            if let old = self.host, old.superview === body { old.removeFromSuperview() }
            self.host = host
            if let host {
                body.addSubview(host, positioned: .below, relativeTo: empty)
            }
            needsLayout = true
        }
        host?.allowsScrim = model.tab?.state != .stopped
        guard model != self.model else { return }
        self.model = model
        setAccessibilityIdentifier(AXID.pane(model.paneId))
        header.update(model)
        header.isHidden = !(model.tab != nil || model.content.isFile)
        empty.isHidden = !(model.tab == nil && !model.content.isFile)
        empty.update(paneId: model.paneId, takesReturn: model.takesReturn)
        fileLabel.isHidden = editor != nil || !model.content.isFile
        fileLabel.stringValue =
            model.content.filePath.map { "\(($0 as NSString).lastPathComponent)\nDiffs open in T4.2." } ?? ""
        if let editor { header.updateFile(dirty: editor.isDirty, meta: editor.headerMeta) }
        exitBar.update(model.tab)

        if let tab = model.tab {
            // The pane speaks its tab and state, such as "terminal-1, running" (ENGINEERING §4.2 rule 4).
            let state = tab.stateLabel.isEmpty ? tab.state.rawValue : tab.stateLabel.lowercased()
            setAccessibilityLabel("\(tab.name), \(state)")
            setAccessibilityValue(tab.state.rawValue)
        } else if let path = model.content.filePath {
            setAccessibilityLabel(path)
            setAccessibilityValue(nil)
        } else {
            setAccessibilityLabel("Empty pane")
            setAccessibilityValue("empty")
        }
        applyColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        let headerHeight: CGFloat = header.isHidden ? 0 : PaneHeaderView.height
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let barHeight: CGFloat = exitBar.isHidden ? 0 : ExitBarView.height
        exitBar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        body.frame = NSRect(
            x: 0, y: headerHeight, width: bounds.width, height: bounds.height - headerHeight - barHeight)
        // The terminal sits 8 below the header and 10 in from the sides (the libghostty padding comes on top).
        host?.frame = body.bounds.insetBy(dx: 10, dy: 8)
        empty.frame = body.bounds
        if let editor, editor.superview === body { editor.frame = body.bounds }
        fileLabel.frame = NSRect(x: 12, y: body.bounds.midY - 20, width: max(body.bounds.width - 24, 0), height: 40)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds.insetBy(dx: -ring.borderWidth, dy: -ring.borderWidth)
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Theme.Radius.pane, cornerHeight: Theme.Radius.pane, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let ringed = model.map { $0.isFocused && $0.showsRing } ?? false
        let failed = model?.tab?.state == .failed && !(model?.isFocused ?? false)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            clip.layer?.backgroundColor = Tokens.pane.cgColor
            clip.layer?.borderColor = (failed ? Tokens.failedBorder : Tokens.paneHairline).cgColor
            let alpha: CGFloat = (model?.isKeyWindow ?? true) ? 1 : 0.35
            ring.borderColor = Tokens.accent.withAlphaComponent(alpha).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 1.5 pt, or 2 under Increase Contrast (UX §9.1), outside the card's edge.
        ring.borderWidth = Theme.focusRingWidth
        ring.cornerRadius = Theme.Radius.pane + ring.borderWidth
        ring.frame = bounds.insetBy(dx: -ring.borderWidth, dy: -ring.borderWidth)
        ring.isHidden = !ringed
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = ringed ? 0.25 : 0
        layer?.shadowRadius = 15
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        CATransaction.commit()
    }

    /// Gives keyboard focus to what the pane shows: its terminal or editor, or the empty pane's New Shell Tab.
    func focusContent() {
        if let host, host.superview === body {
            host.focus()
        } else if let editor, editor.superview === body {
            editor.focus()
        } else if !empty.isHidden {
            empty.focusDefault()
        }
    }

    /// Close Pane from the header: a dirty file asks first (UX §4.2).
    private func close() {
        guard let model else { return }
        guard let path = editor?.path else { return actions.closePane(model.paneId) }
        Task {
            guard await FileEditors.confirmClose(path: path, window: window) else { return }
            actions.closePane(model.paneId)
        }
    }

    /// Whether `view` is inside this card's body.
    func contains(_ view: NSView) -> Bool {
        view.isDescendant(of: self)
    }
}

extension PaneContent {
    var isFile: Bool { filePath != nil }

    var filePath: String? {
        switch self {
        case .file(let path): path
        case .diff(let ref): ref.path
        case .tab, .empty: nil
        }
    }
}

// MARK: - Header

/// The pane header (UX §4.1): kind icon, title, state word; meta and actions at the right. 36 tall, a rule
/// below. `pane.header:<tabName>` holds `pane.stop:<tabName>` and `pane.close:<paneId>`; Close fades in
/// while the pointer is over the header and stays in the accessibility tree.
final class PaneHeaderView: NSView {
    static let height: CGFloat = 36

    var onClose: (() -> Void)?
    var onStop: (() -> Void)?
    /// A file picked in the recent-files pull-down, and Clear Recent Files (UX §6.1).
    var onOpenRecent: ((String) -> Void)?
    var onClearRecent: (() -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let branchIcon = NSImageView()
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let close = NSButton(
        image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane") ?? NSImage(),
        target: nil, action: nil)
    private let recent = NSButton(
        image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Recent Files") ?? NSImage(),
        target: nil, action: nil)
    private let rule = NSView()
    private var isFocused = false
    /// The file pane's path, recent files and dirty state.
    private var filePath: String?
    private var recentFiles: [String] = []
    private var isDirty = false
    private var hovering = false {
        didSet {
            updateCloseAlpha()
            updateCloseImage()
        }
    }
    private var alwaysShowsClose = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        for label in [state, detail, meta] {
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingHead
        }
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        branchIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        stop.bezelStyle = .accessoryBarAction
        stop.controlSize = .small
        stop.font = .systemFont(ofSize: 12)
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stop.imagePosition = .imageLeading
        stop.target = self
        stop.action = #selector(stopPressed)
        stop.toolTip = "Stop Command (⌘.)"
        close.bezelStyle = .accessoryBarAction
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        close.target = self
        close.action = #selector(closePressed)
        close.toolTip = "Close Pane (⌘W)"
        close.setAccessibilityLabel("Close Pane")
        recent.bezelStyle = .accessoryBarAction
        recent.isBordered = false
        recent.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        recent.target = self
        recent.action = #selector(recentPressed)
        recent.toolTip = "Recent Files"
        recent.setAccessibilityLabel("Recent Files")
        recent.isHidden = true
        rule.wantsLayer = true

        let leading = NSStackView(views: [icon, title, recent, state, detail])
        leading.spacing = 8
        leading.setCustomSpacing(2, after: title)
        leading.setHuggingPriority(.defaultLow, for: .horizontal)
        let trailing = NSStackView(views: [branchIcon, meta, stop, close])
        trailing.spacing = 8
        trailing.setCustomSpacing(4, after: branchIcon)
        for stack in [leading, trailing] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 8),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24),
            recent.widthAnchor.constraint(equalToConstant: 16),
            recent.heightAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneHeaderView is built in code")
    }

    func update(_ model: PaneCardModel) {
        isFocused = model.isFocused
        close.setAXIdentifier(AXID.paneClose(model.paneId))
        if let tab = model.tab {
            setAccessibilityIdentifier(AXID.paneHeader(tab.name))
            icon.image = NSImage(
                systemSymbolName: tab.isAgent ? "sparkle" : "terminal", accessibilityDescription: nil)
            title.stringValue = tab.title.isEmpty ? tab.name : tab.title
            let (word, color, extra) = Self.stateWord(tab)
            state.stringValue = word
            state.textColor = color
            state.isHidden = word.isEmpty
            detail.stringValue = extra ?? ""
            detail.isHidden = extra == nil
            let folder = (tab.cwd as NSString).lastPathComponent
            meta.stringValue = [folder, model.branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            meta.toolTip = (tab.cwd as NSString).abbreviatingWithTildeInPath
            branchIcon.isHidden = model.branch == nil
            stop.isHidden = tab.state != .running
            stop.setAXIdentifier(AXID.paneStop(tab.name))
            stop.setAccessibilityLabel("Stop \(tab.name)")
            setAccessibilityLabel("\(tab.name) header")
            alwaysShowsClose = false
            recent.isHidden = true
            filePath = nil
            isDirty = false
        } else if let path = model.content.filePath {
            setAccessibilityIdentifier(AXID.paneHeader(path))
            icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            title.stringValue = (path as NSString).lastPathComponent
            state.isHidden = true
            detail.isHidden = true
            meta.stringValue = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            branchIcon.isHidden = true
            stop.isHidden = true
            setAccessibilityLabel("\(title.stringValue) header")
            alwaysShowsClose = true
            if filePath != path { isDirty = false }
            filePath = path
            recentFiles = model.recentFiles
            recent.isHidden = model.recentFiles.isEmpty
            recent.setAXIdentifier(AXID.paneRecent(model.paneId))
        }
        updateCloseImage()
        updateCloseAlpha()
        applyColors()
    }

    /// A file's dirty state and, for previews, the meta that replaces the folder ("1280 × 800 · 214 KB").
    func updateFile(dirty: Bool, meta previewMeta: String?) {
        guard let filePath else { return }
        isDirty = dirty
        if let previewMeta {
            meta.stringValue = previewMeta
            meta.toolTip = (filePath as NSString).abbreviatingWithTildeInPath
        }
        updateCloseImage()
    }

    /// While a file is dirty, Close shows a 6 pt dot that turns into `xmark` on hover, and says "edited"
    /// (UX §6.1).
    private func updateCloseImage() {
        let name = filePath.map { ($0 as NSString).lastPathComponent }
        if isDirty, let name {
            close.image = hovering ? Self.xmark : Self.dirtyDot
            close.setAccessibilityLabel("\(name), edited")
            close.setAccessibilityValue("edited")
        } else {
            close.image = Self.xmark
            close.setAccessibilityLabel("Close Pane")
            close.setAccessibilityValue(nil)
        }
    }

    private static let xmark = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane") ?? NSImage()
    private static let dirtyDot = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { rect in
        Tokens.textBody.setFill()
        NSBezierPath(ovalIn: rect).fill()
        return true
    }

    /// The recent-files pull-down: "session.ts · backend/src/auth", newest first, a checkmark on the current
    /// file, then Clear Recent Files.
    @objc private func recentPressed() {
        let menu = NSMenu()
        for path in recentFiles.prefix(10) {
            let folder = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            let item = NSMenuItem(
                title: "\((path as NSString).lastPathComponent) · \(folder)", action: #selector(recentPicked(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.state = path == filePath ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Recent Files", action: #selector(clearPicked), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: recent.bounds.maxY + 4), in: recent)
    }

    @objc private func recentPicked(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, path != filePath else { return }
        onOpenRecent?(path)
    }

    @objc private func clearPicked() { onClearRecent?() }

    /// The state word of UX §4.1: nothing when idle.
    private static func stateWord(_ tab: TabSummary) -> (String, NSColor, String?) {
        switch tab.state {
        case .running: ("Running", Tokens.running, nil)
        case .done: ("Done", Tokens.done, nil)
        case .failed: ("Failed", Tokens.failed, tab.stateDetail ?? tab.lastExit.map { "exit \($0.code)" })
        case .needsYou: ("Needs you", Tokens.needs, nil)
        case .stopped: ("Stopped", Tokens.stopped, tab.stateDetail)
        default: ("", Tokens.textSecondary, nil)
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Hidden Close keeps a sliver of alpha so it stays in the accessibility tree (UX §4.1).
    private func updateCloseAlpha() {
        let shown = hovering || alwaysShowsClose
        let target: CGFloat = shown ? 1 : 0.001
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            close.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.12 : 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            close.animator().alphaValue = target
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        title.textColor = Tokens.textPrimary
        detail.textColor = Tokens.textSecondary
        meta.textColor = Tokens.textSecondary
        icon.contentTintColor = isFocused ? Tokens.iconFocused : Tokens.icon
        branchIcon.contentTintColor = Tokens.textSecondary
        close.contentTintColor = Tokens.icon
        recent.contentTintColor = Tokens.icon
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rule.layer?.backgroundColor = Tokens.paneDivider.cgColor
        }
    }

    @objc private func closePressed() { onClose?() }
    @objc private func stopPressed() { onStop?() }
}

// MARK: - Empty pane

/// The empty pane (UX §4.4): "Empty pane", [New Shell Tab] ⌘T, [New Agent Tab] ⇧⌘T, and a hint.
/// Return triggers New Shell Tab in the focused empty pane.
private final class EmptyPaneView: NSView {
    var onNewTab: ((String) -> Void)?

    private let title = NSTextField(labelWithString: "Empty pane")
    private let newShell = NSButton(title: "New Shell Tab", target: nil, action: nil)
    private let newAgent = NSButton(title: "New Agent Tab", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "Or choose a tab in the sidebar.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Tokens.textSecondary
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = Tokens.textSecondary
        newShell.bezelStyle = .push
        newShell.font = .systemFont(ofSize: 12, weight: .semibold)
        newShell.tintProminence = .primary
        newShell.target = self
        newShell.action = #selector(shellPressed)
        newAgent.bezelStyle = .push
        newAgent.font = .systemFont(ofSize: 12)
        newAgent.target = self
        newAgent.action = #selector(agentPressed)
        let rows = [(newShell, "⌘T"), (newAgent, "⇧⌘T")].map { button, key -> NSView in
            let label = NSTextField(labelWithString: key)
            label.font = .systemFont(ofSize: 12)
            label.textColor = Tokens.textSecondary
            let row = NSStackView(views: [button, label])
            row.spacing = 8
            return row
        }
        let stack = NSStackView(views: [title] + rows + [hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EmptyPaneView is built in code")
    }

    func update(paneId: String, takesReturn: Bool) {
        newShell.setAXIdentifier(AXID.paneEmptyNewShell(paneId))
        newAgent.setAXIdentifier(AXID.paneEmptyNewAgent(paneId))
        newShell.keyEquivalent = takesReturn ? "\r" : ""
    }

    func focusDefault() {
        window?.makeFirstResponder(newShell)
    }

    @objc private func shellPressed() { onNewTab?("shell") }
    @objc private func agentPressed() { onNewTab?("agent") }
}

// MARK: - Exit bar

/// The bar at the bottom of a stopped shell's pane (UX §4.3): "The shell exited with code {n}." with
/// [Restart] (`pane.restart:<tabName>`) and [Close Tab] (`pane.closeTab:<tabName>`).
private final class ExitBarView: NSView {
    static let height: CGFloat = 40

    var onRestart: (() -> Void)?
    var onCloseTab: (() -> Void)?

    private let message = NSTextField(labelWithString: "")
    private let restart = NSButton(title: "Restart", target: nil, action: nil)
    private let closeTab = NSButton(title: "Close Tab", target: nil, action: nil)
    private let rule = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        message.font = .systemFont(ofSize: 12)
        message.lineBreakMode = .byTruncatingTail
        for button in [restart, closeTab] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
            button.target = self
        }
        restart.tintProminence = .primary
        restart.action = #selector(restartPressed)
        closeTab.action = #selector(closePressed)
        rule.wantsLayer = true
        let stack = NSStackView(views: [message, restart, closeTab])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(rule)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ExitBarView is built in code")
    }

    func update(_ tab: TabSummary?) {
        guard let tab, tab.state == .stopped else {
            isHidden = true
            return
        }
        isHidden = false
        let code = tab.lastExit?.code ?? Self.code(from: tab.stateDetail)
        message.stringValue = code.map { "The shell exited with code \($0)." } ?? "The shell exited."
        message.textColor = Tokens.textBody
        setAccessibilityLabel(message.stringValue)
        restart.setAXIdentifier(AXID.paneRestart(tab.name))
        closeTab.setAXIdentifier(AXID.paneCloseTab(tab.name))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rule.layer?.backgroundColor = Tokens.paneDivider.cgColor
        }
    }

    /// "exit 3" → 3.
    private static func code(from detail: String?) -> Int? {
        guard let detail, detail.hasPrefix("exit ") else { return nil }
        return Int(detail.dropFirst(5))
    }

    @objc private func restartPressed() { onRestart?() }
    @objc private func closePressed() { onCloseTab?() }
}
