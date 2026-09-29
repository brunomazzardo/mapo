import AppKit
import MapoClient

/// What the Changes segment shows instead of its list (UX §5.3 states).
enum ChangesState: String {
    case loading
    case ready
    case clean
    case notRepository = "not-a-repository"
    case error
    case noTerminal = "no-terminal"
}

enum ChangesText {
    /// `(title, body)` for a state; nil for `ready`.
    static func copy(_ state: ChangesState, path: String, error: String?) -> (String, String)? {
        switch state {
        case .ready: nil
        case .loading: ("Loading changes…", "")
        case .clean: ("No changes", "The working tree matches HEAD.")
        case .notRepository: ("Not a git repository", "\(FilesText.tildePath(path)) isn't inside a git repository.")
        case .error:
            ("Couldn't read git status", "\(error ?? "git failed"). Fix it in a terminal, then retry.")
        case .noTerminal: ("No terminal focused", "Focus a terminal to see its repository's changes.")
        }
    }

    /// The row's accessibility value: the raw status letter and the counts, such as "M +2 -1" or "A bin".
    static func rowValue(_ file: GitChanges.File) -> String {
        file.binary == true ? "\(file.status) bin" : "\(file.status) +\(file.added) -\(file.deleted)"
    }

    /// "main ↑2 ↓1", "main, no upstream" or "detached at a7bc6c9".
    static func branch(_ changes: GitChanges) -> (name: String, upstream: String) {
        guard let branch = changes.branch else {
            return (changes.head.map { "detached at \($0)" } ?? "no commit yet", "")
        }
        guard changes.upstream != nil else { return (branch, "no upstream") }
        var sides: [String] = []
        if changes.ahead > 0 { sides.append("↑\(changes.ahead)") }
        if changes.behind > 0 { sides.append("↓\(changes.behind)") }
        return (branch, sides.joined(separator: " "))
    }
}

/// The summary row (`inspector.changes.summary`, UX §5.3): branch and upstream at the left, "3 files +87 −6"
/// at the right. Its value reads "main, 3 files, +87 -6".
final class ChangesSummaryView: NSView {
    private let icon = NSImageView()
    private let branch = NSTextField(labelWithString: "")
    private let upstream = NSTextField(labelWithString: "")
    private let files = NSTextField(labelWithString: "")
    private let added = NSTextField(labelWithString: "")
    private let deleted = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AXID.inspectorChangesSummary)
        icon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = Tokens.icon
        branch.textColor = Tokens.textBody
        branch.lineBreakMode = .byTruncatingTail
        upstream.textColor = Tokens.textSecondary
        files.textColor = Tokens.textSecondary
        added.textColor = Tokens.done
        deleted.textColor = Tokens.failed
        for label in [branch, upstream, files, added, deleted] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            addSubview(label)
        }
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChangesSummaryView is built in code")
    }

    func configure(_ changes: GitChanges) {
        let (name, up) = ChangesText.branch(changes)
        branch.stringValue = name
        upstream.stringValue = up
        let count = changes.totals.files
        files.stringValue = count == 1 ? "1 file" : "\(count) files"
        added.stringValue = "+\(changes.totals.added)"
        deleted.stringValue = "−\(changes.totals.deleted)"
        added.isHidden = changes.totals.added == 0
        deleted.isHidden = changes.totals.deleted == 0
        if let upstreamName = changes.upstream {
            toolTip = "Upstream \(upstreamName): \(changes.ahead) ahead, \(changes.behind) behind"
        } else {
            toolTip = nil
        }
        setAccessibilityLabel(name)
        setAccessibilityValue(
            "\(name), \(files.stringValue), +\(changes.totals.added) -\(changes.totals.deleted)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        func place(_ view: NSView, x: CGFloat, width: CGFloat? = nil) -> CGFloat {
            if let field = view as? NSTextField { field.sizeToFit() }
            let size = view.fittingSize
            let w = width ?? size.width
            view.frame = NSRect(x: x, y: midY - size.height / 2, width: w, height: size.height)
            return x + w
        }
        var right = bounds.width - 16
        for label in [deleted, added, files] where !label.isHidden {
            label.sizeToFit()
            right -= label.frame.width
            label.frame.origin = NSPoint(x: right, y: midY - label.frame.height / 2)
            right -= 6
        }
        var x = place(icon, x: 16, width: 14) + 6
        upstream.sizeToFit()
        let branchWidth = max(0, min(branch.fittingSize.width, right - x - upstream.frame.width - 12))
        x = place(branch, x: x, width: branchWidth) + 6
        _ = place(upstream, x: x)
    }
}

/// The size warning (`inspector.changes.warning`, R-GIT-1): the daemon's string with a triangle.
final class ChangesWarningView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier(AXID.inspectorChangesWarning)
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = Tokens.needs
        label.font = .systemFont(ofSize: 12)
        label.textColor = Tokens.textBody
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChangesWarningView is built in code")
    }

    func configure(_ text: String) {
        label.stringValue = text
        setAccessibilityLabel(text)
        setAccessibilityValue(text)
        needsLayout = true
    }

    /// The height for `width`.
    func height(for width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = max(0, width - 16 - 20 - 16)
        return max(28, label.fittingSize.height + 12)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 16, y: 7, width: 14, height: 14)
        label.preferredMaxLayoutWidth = max(0, bounds.width - 52)
        label.frame = NSRect(x: 36, y: 6, width: max(0, bounds.width - 52), height: bounds.height - 12)
    }

    override var isFlipped: Bool { true }
}

/// A changed file (`inspector.changes.row:<relPath>`, UX §5.3): letter, name, folder, +N −N. Its value is
/// `ChangesText.rowValue`.
final class ChangesRowView: NSView {
    static let height: CGFloat = 26

    let file: GitChanges.File
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    var onPress: ((_ doubleClick: Bool) -> Void)?

    private let letter = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let added = NSTextField(labelWithString: "")
    private let deleted = NSTextField(labelWithString: "")
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init(_ file: GitChanges.File, absolutePath: String) {
        self.file = file
        super.init(frame: .zero)
        let shown = FilesText.letter(file.status) ?? file.status
        let color = filesGitColor(file.status) ?? Tokens.textBody
        letter.stringValue = shown
        letter.font = .systemFont(ofSize: 11, weight: .bold)
        letter.textColor = color
        letter.alignment = .center
        let parts = file.path.split(separator: "/")
        name.stringValue = parts.last.map(String.init) ?? file.path
        name.font = .systemFont(ofSize: 13)
        name.textColor = Tokens.textBody
        name.lineBreakMode = .byTruncatingTail
        folder.stringValue = parts.dropLast().joined(separator: "/")
        folder.font = .systemFont(ofSize: 12)
        folder.textColor = Tokens.textSecondary
        folder.lineBreakMode = .byTruncatingHead
        for label in [added, deleted] { label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
        if file.binary == true {
            added.stringValue = "bin"
            added.textColor = Tokens.textSecondary
            deleted.isHidden = true
        } else {
            added.stringValue = "+\(file.added)"
            added.textColor = Tokens.done
            added.isHidden = file.added == 0
            deleted.stringValue = "−\(file.deleted)"
            deleted.textColor = Tokens.failed
            deleted.isHidden = file.deleted == 0
        }
        for view in [letter, name, folder, added, deleted] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityIdentifier(AXID.inspectorChangesRow(file.path))
        let spoken = FilesText.spoken(file.status).map { ", \($0)" } ?? ""
        setAccessibilityLabel("\(file.path)\(spoken)")
        setAccessibilityValue(ChangesText.rowValue(file))
        toolTip = absolutePath
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChangesRowView is built in code")
    }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityPerformPress() -> Bool {
        onPress?(false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(event.clickCount >= 2)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8 + 8
        func center(_ label: NSTextField) -> CGFloat {
            label.sizeToFit()
            return (bounds.height - label.frame.height) / 2
        }
        var right = bounds.width - inset
        for label in [deleted, added] where !label.isHidden {
            label.sizeToFit()
            right -= label.frame.width
            label.frame.origin = NSPoint(x: right, y: center(label))
            right -= 6
        }
        letter.frame = NSRect(x: inset, y: center(letter), width: 12, height: letter.frame.height)
        var x = letter.frame.maxX + 6
        let nameWidth = min(name.fittingSize.width, max(0, right - x))
        name.frame = NSRect(x: x, y: center(name), width: nameWidth, height: name.frame.height)
        x = name.frame.maxX + 6
        folder.frame = NSRect(x: x, y: center(folder), width: max(0, right - x), height: folder.frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor? = isSelected ? Tokens.selection : (isHovered ? Tokens.hover : nil)
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// The list's document view: rows stacked top-down. It takes keyboard focus on a click so ↑ ↓ step through
/// diffs and Return opens the file (UX §5.3).
final class ChangesListView: NSView {
    var onMove: ((Int) -> Void)?
    var onReturn: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onMove?(-1)
        case 125: onMove?(1)
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }
}

/// A centered state (`inspector.changes.state`) whose value is the state name, with Retry
/// (`inspector.changes.retry`) after an error.
final class ChangesStateView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AXID.inspectorChangesState)
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
        retry.setAXIdentifier(AXID.inspectorChangesRetry)
        retry.setAccessibilityLabel("Retry")
        let stack = NSStackView(views: [title, body, retry])
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
        fatalError("ChangesStateView is built in code")
    }

    func configure(_ state: ChangesState, path: String, error: String?) {
        let copy = ChangesText.copy(state, path: path, error: error) ?? ("", "")
        title.stringValue = copy.0
        body.stringValue = copy.1
        body.isHidden = copy.1.isEmpty
        retry.isHidden = state != .error
        setAccessibilityValue(state.rawValue)
        setAccessibilityLabel(copy.1.isEmpty ? copy.0 : "\(copy.0). \(copy.1)")
    }

    @objc private func retryPressed() {
        onRetry?()
    }
}
