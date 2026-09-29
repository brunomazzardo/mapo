import AppKit

/// Files tree metrics (UX §5.2).
enum FilesMetrics {
    static let rowHeight: CGFloat = 26
    static let listInset: CGFloat = 8
    static let indent: CGFloat = 18
    static let radius: CGFloat = 6
    static let gap: CGFloat = 6
}

/// The color of a `git` value (UX §5.2).
@MainActor
func filesGitColor(_ git: String?) -> NSColor? {
    switch git {
    case "M": Tokens.needs
    case "A", "R", "?": Tokens.done
    case "U", "D": Tokens.failed
    default: nil
    }
}

/// The Files outline. Its accessibility children are the `FilesRowView`s, which carry the identifiers, labels
/// and git values; Return opens the selected row; type-to-select and the arrow keys are AppKit's.
final class FilesOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    /// A light stand-in for a row that has no row view (scrolled away), so `ui.tree` lists every row
    /// without building views for them.
    var accessibilityRow: ((Int) -> Any?)?

    override func accessibilityChildren() -> [Any]? {
        (0..<numberOfRows).compactMap { rowView(atRow: $0, makeIfNecessary: false) ?? accessibilityRow?($0) }
    }

    /// The cells draw their own chevrons (UX §5.2). Hiding AppKit's disclosure triangle this way, rather than
    /// through `shouldShowOutlineCellForItem`, keeps `collapseItem` working.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
    }

    /// Set by the click action; see `mouseDown`.
    var didSendClick = false
    var onUnhandledClick: ((Int) -> Void)?

    /// A click selects the row and puts keyboard focus in the tree, so the arrows, Return and type-to-select
    /// work next; nothing else moves focus here. While the app is inactive, AppKit's tracking can end without
    /// sending the action, so the click is handled here then.
    override func mouseDown(with event: NSEvent) {
        didSendClick = false
        super.mouseDown(with: event)
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard !didSendClick, row >= 0 else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onUnhandledClick?(row)
    }

    override func keyDown(with event: NSEvent) {
        // Return and keypad Enter.
        if event.keyCode == 36 || event.keyCode == 76, let onReturn {
            onReturn()
            return
        }
        super.keyDown(with: event)
    }

    /// Right-clicking a row selects it for the menu without opening it, like Finder.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

/// A Files row: background, hover, and the accessibility element (`inspector.files.row:<relPath>`), whose
/// value is the raw `git` value.
final class FilesRowView: NSTableRowView {
    private(set) var node: FileNode?
    var onPress: (() -> Void)?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    func configure(_ node: FileNode, expanded: Bool) {
        self.node = node
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier(AXID.inspectorFilesRow(node.relativePath))
        setAccessibilityLabel(FilesText.rowLabel(node, expanded: expanded))
        setAccessibilityValue(node.git)
        toolTip = node.path
        needsDisplay = true
    }

    /// The row speaks for its cell; walking into the cell's labels only costs time.
    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let fill: NSColor? = isSelected ? Tokens.selection : (isHovered ? Tokens.hover : nil)
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: FilesMetrics.listInset, dy: 0), xRadius: FilesMetrics.radius,
            yRadius: FilesMetrics.radius
        ).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }
}

/// The accessibility element of a row without a row view; the same identifier, label and value.
/// AppKit calls it on the main thread only.
nonisolated final class FilesRowElement: NSAccessibilityElement {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?

    @MainActor
    func configure(_ node: FileNode, expanded: Bool, frame: NSRect, parent: NSView) {
        setAccessibilityRole(.row)
        setAccessibilityIdentifier(AXID.inspectorFilesRow(node.relativePath))
        setAccessibilityLabel(FilesText.rowLabel(node, expanded: expanded))
        setAccessibilityValue(node.git)
        setAccessibilityParent(parent)
        setAccessibilityFrame(frame)
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        MainActor.assumeIsolated { onPress() }
        return true
    }
}

/// A Files row's contents: chevron (folders), icon, name, then the git letter, or a dot on a collapsed
/// folder with changes. Laid out by hand.
final class FilesCellView: NSTableCellView {
    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let letter = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var depth = 0
    private var isFolder = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for image in [chevron, icon] {
            image.imageScaling = .scaleProportionallyDown
            image.setAccessibilityElement(false)
            image.cell?.setAccessibilityElement(false)
            addSubview(image)
        }
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = Tokens.icon
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = Tokens.icon
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        letter.font = .systemFont(ofSize: 11, weight: .bold)
        letter.alignment = .right
        for label in [name, letter] {
            label.setAccessibilityElement(false)
            label.cell?.setAccessibilityElement(false)
            addSubview(label)
        }
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.setAccessibilityElement(false)
        addSubview(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FilesCellView is built in code")
    }

    func configure(_ node: FileNode, expanded: Bool) {
        depth = node.depth
        isFolder = node.isFolder
        chevron.isHidden = !node.isFolder
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        icon.image = NSImage(systemSymbolName: node.isFolder ? "folder" : "doc", accessibilityDescription: nil)
        name.stringValue = node.name
        let color = filesGitColor(node.git)
        name.textColor = color ?? Tokens.textBody
        let showDot = node.isFolder && !expanded && color != nil
        let showLetter = !node.isFolder && color != nil
        letter.stringValue = showLetter ? (FilesText.letter(node.git) ?? "") : ""
        letter.textColor = color
        letter.isHidden = !showLetter
        dot.isHidden = !showDot
        dot.layer?.backgroundColor = color?.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x = FilesMetrics.listInset * 2 + FilesMetrics.indent * CGFloat(depth)
        if isFolder {
            chevron.frame = NSRect(x: x, y: (height - 12) / 2, width: 12, height: 12)
        }
        x += FilesMetrics.indent
        icon.frame = NSRect(x: x, y: (height - 16) / 2, width: 16, height: 16)
        x += 16 + FilesMetrics.gap
        let trailing = bounds.width - FilesMetrics.listInset - 8
        var nameEnd = trailing
        if !letter.isHidden {
            letter.frame = NSRect(x: trailing - 14, y: (height - 14) / 2, width: 14, height: 14)
            nameEnd = letter.frame.minX - FilesMetrics.gap
        }
        if !dot.isHidden {
            dot.frame = NSRect(x: trailing - 6, y: (height - 6) / 2, width: 6, height: 6)
            nameEnd = dot.frame.minX - FilesMetrics.gap
        }
        let nameHeight = name.intrinsicContentSize.height
        name.frame = NSRect(x: x, y: (height - nameHeight) / 2, width: max(0, nameEnd - x), height: nameHeight)
    }
}

/// The Files header (`inspector.files.header`): folder icon, the root as a `~` path truncated at the head,
/// and the branch chip inside a repository.
final class FilesHeaderView: NSView {
    private let icon = NSImageView()
    private let path = NSTextField(labelWithString: "")
    private let chip = NSView()
    private let chipIcon = NSImageView()
    private let branch = NSTextField(labelWithString: "")
    private var fullPath: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AXID.inspectorFilesHeader)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = Tokens.icon
        path.font = .systemFont(ofSize: 12)
        path.textColor = Tokens.textBody
        path.lineBreakMode = .byTruncatingHead
        chipIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        chipIcon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        chipIcon.contentTintColor = Tokens.textSecondaryOnSelection
        branch.font = .systemFont(ofSize: 11)
        branch.textColor = Tokens.textSecondaryOnSelection
        branch.lineBreakMode = .byTruncatingTail
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        chip.layer?.backgroundColor = Tokens.hover.cgColor
        for view in [icon, path, chipIcon, branch, chip] as [NSView] {
            view.setAccessibilityElement(false)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for label in [path, branch] { label.cell?.setAccessibilityElement(false) }
        chip.addSubview(chipIcon)
        chip.addSubview(branch)
        addSubview(icon)
        addSubview(path)
        addSubview(chip)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branch.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            path.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            path.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: path.trailingAnchor, constant: 8),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: 18),
            chipIcon.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            chipIcon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            branch.leadingAnchor.constraint(equalTo: chipIcon.trailingAnchor, constant: 3),
            branch.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            branch.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            branch.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
        ])
        let trailingPath = path.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        trailingPath.priority = .defaultLow
        trailingPath.isActive = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FilesHeaderView is built in code")
    }

    func configure(path root: String?, branch name: String?) {
        fullPath = root
        let shown = root.map(FilesText.tildePath) ?? ""
        path.stringValue = shown
        path.toolTip = root
        branch.stringValue = name ?? ""
        chip.isHidden = name == nil
        isHidden = root == nil
        var label = shown.isEmpty ? "No folder" : shown
        if let name { label += ", branch \(name)" }
        setAccessibilityLabel(label)
        setAccessibilityValue(root)
    }

    @objc private func copyPath() {
        guard let fullPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullPath, forType: .string)
    }

    @objc private func reveal() {
        guard let fullPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
    }
}

/// A centered state (`inspector.files.state`, R-FS-5) whose accessibility value is the state name, with
/// Retry (`inspector.files.retry`) where one applies.
final class FilesStateView: NSView {
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AXID.inspectorFilesState)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Tokens.textSecondary
        title.alignment = .center
        body.font = .systemFont(ofSize: 12)
        body.textColor = Tokens.textSecondary
        body.alignment = .center
        retry.bezelStyle = .push
        retry.controlSize = .small
        retry.target = self
        retry.action = #selector(retryPressed)
        retry.setAXIdentifier(AXID.inspectorFilesRetry)
        retry.setAccessibilityLabel("Retry")
        let stack = NSStackView(views: [spinner, title, body, retry])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FilesStateView is built in code")
    }

    func configure(_ state: FilesState, path: String, hiddenByExclude: Int) {
        let copy = FilesText.copy(state, path: path, hiddenByExclude: hiddenByExclude) ?? ("", "")
        title.stringValue = copy.0
        body.stringValue = copy.1
        body.isHidden = copy.1.isEmpty
        if state == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        retry.isHidden = !(state == .missing || state == .unreadable)
        setAccessibilityValue(state.rawValue)
        setAccessibilityLabel(copy.1.isEmpty ? copy.0 : "\(copy.0). \(copy.1)")
    }

    @objc private func retryPressed() {
        onRetry?()
    }
}
