import AppKit

/// The rail's horizontal insets: the list inset of 8 (UX §3), then row padding.
enum RailMetrics {
    static let listInset: CGFloat = 8
    static let padding: CGFloat = 10
    static let tabIndent: CGFloat = 26
    static let radius: CGFloat = 6
    /// The hold-⌘ hint column (UX §3.3).
    static let hintWidth: CGFloat = 22
}

/// A rail row's background and accessibility element. The row, not its cell, carries the identifier, the
/// spoken label and the raw state as its value (UX §3.8).
final class RailRowView: NSTableRowView {
    private(set) var row: RailRow?
    var onPress: (() -> Void)?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    func configure(_ row: RailRow) {
        self.row = row
        toolTip = row.tooltip
        if let identifier = row.identifier, row.isInteractive {
            setAccessibilityElement(true)
            setAccessibilityRole(.row)
            setAccessibilityIdentifier(identifier)
            setAccessibilityLabel(row.label)
            setAccessibilityValue(row.state.rawValue)
            setAccessibilityHelp(row.help)
            setAccessibilitySelected(row.isSelected)
        } else {
            // Headers and placeholders are text, not rows; the tree walks through them to their children.
            setAccessibilityElement(false)
            setAccessibilityIdentifier(nil)
        }
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard row?.isInteractive == true, let onPress else { return false }
        onPress()
        return true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let row, row.isInteractive else { return }
        let fill: NSColor?
        if row.isSelected {
            fill = Tokens.selection
        } else if isHovered {
            fill = Tokens.hover
        } else {
            fill = nil
        }
        guard let fill else { return }
        var rect = bounds.insetBy(dx: RailMetrics.listInset, dy: 0)
        rect.size.height = row.contentHeight
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: RailMetrics.radius, yRadius: RailMetrics.radius).fill()
    }

    // The rail draws its own selection (UX §3.2); the table's is off.
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

/// A rail row's contents: chevron or kind icon, name, branch and accessory, laid out by hand.
final class RailCellView: NSTableCellView {
    private let glyph = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let accessory = RailAccessoryView()
    private let hint = NSTextField(labelWithString: "")
    private let button = NSButton(title: "New Workspace", target: nil, action: nil)
    private var row: RailRow?

    var onButton: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hint.alignment = .right
        hint.font = .systemFont(ofSize: 11)
        for label in [name, secondary, hint] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.setAccessibilityElement(false)
            label.cell?.setAccessibilityElement(false)
            addSubview(label)
        }
        glyph.imageScaling = .scaleProportionallyDown
        glyph.setAccessibilityElement(false)
        glyph.cell?.setAccessibilityElement(false)
        addSubview(glyph)
        addSubview(accessory)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.font = .systemFont(ofSize: 12.5)
        button.contentTintColor = Tokens.accent
        button.target = self
        button.action = #selector(buttonPressed)
        button.setAXIdentifier(AXID.railEmptyNewWorkspace)
        button.setAccessibilityLabel("New Workspace")
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RailCellView is built in code")
    }

    override var isFlipped: Bool { true }

    func configure(_ row: RailRow) {
        self.row = row
        button.isHidden = row.kind != .newWorkspaceButton
        glyph.isHidden = true
        secondary.isHidden = true
        name.isHidden = row.kind == .newWorkspaceButton || row.kind == .gap
        name.stringValue = row.text
        switch row.kind {
        case .header:
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            name.textColor = Tokens.textSecondary
        case .noTabs, .noWorkspaces:
            name.font = .systemFont(ofSize: 12.5)
            name.textColor = Tokens.textSecondary
        case .newWorkspaceButton, .gap:
            break
        case .workspace(let expanded, let active):
            glyph.isHidden = false
            glyph.image = NSImage(
                systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            glyph.contentTintColor = Tokens.icon
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.textColor = active ? Tokens.textPrimary : Tokens.textBody
            if let branch = row.secondaryText, !branch.isEmpty {
                secondary.isHidden = false
                secondary.stringValue = branch
                secondary.font = .systemFont(ofSize: 11.5)
                secondary.textColor = Tokens.textSecondary
            }
        case .tab(let icon, let selected):
            glyph.isHidden = false
            glyph.image = RailIcons.image(for: icon)
            glyph.contentTintColor = selected ? Tokens.iconSelected : Tokens.icon
            name.font = .systemFont(ofSize: 12.5)
            name.textColor = Self.nameColor(tint: row.tint, selected: selected)
        }
        let isWorkspace = if case .workspace = row.kind { true } else { false }
        accessory.configure(
            row.accessory, selected: row.isSelected,
            badgeIdentifier: isWorkspace ? AXID.railWorkspaceBadge(row.text) : nil)
        configureHint(row.hint, selected: row.isSelected)
        needsLayout = true
    }

    /// Shows or hides the ⌘ hint, fading it in over 120 ms unless Reduce Motion is on (UX §9.3).
    private func configureHint(_ text: String?, selected: Bool) {
        hint.textColor = selected ? Tokens.textSecondaryOnSelection : Tokens.textSecondary
        guard let text else {
            hint.isHidden = true
            return
        }
        let appearing = hint.isHidden
        hint.stringValue = text
        hint.isHidden = false
        guard appearing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hint.alphaValue = 1
            return
        }
        hint.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hint.animator().alphaValue = 1
        }
    }

    /// Where the name sits, in the cell's coordinates, and the width it may grow to; the rename field
    /// takes this place (UX §3.4).
    var nameEditingFrame: NSRect {
        layoutSubtreeIfNeeded()
        var frame = name.frame
        frame.size.width = max(frame.width, nameMaxX - frame.minX)
        return frame
    }

    var nameFont: NSFont? { name.font }

    private var nameMaxX: CGFloat = 0

    private static func nameColor(tint: RailTone?, selected: Bool) -> NSColor {
        switch tint {
        case .needs: Tokens.needsTint
        case .failed: Tokens.failedTint
        case .muted: Tokens.textSecondary
        default: selected ? Tokens.textPrimary : Tokens.textBody
        }
    }

    override func layout() {
        super.layout()
        guard let row else { return }
        let rowHeight = CGFloat(row.contentHeight)
        let leading = RailMetrics.listInset + RailMetrics.padding
        let trailing = bounds.width - RailMetrics.listInset - RailMetrics.padding
        var x = leading
        switch row.kind {
        case .workspace:
            glyph.frame = NSRect(x: x, y: (rowHeight - 11) / 2, width: 11, height: 11)
            x += 11 + 7
        case .tab:
            x = RailMetrics.listInset + RailMetrics.tabIndent
            glyph.frame = NSRect(x: x, y: (rowHeight - 12) / 2, width: 12, height: 12)
            x += 12 + 8
        case .noTabs:
            x = RailMetrics.listInset + RailMetrics.tabIndent
        case .newWorkspaceButton:
            button.sizeToFit()
            button.frame.origin = NSPoint(x: leading - 4, y: (rowHeight - button.frame.height) / 2)
            return
        default:
            break
        }
        var accessoryEnd = trailing
        if !hint.isHidden {
            let hintHeight = ceil(hint.intrinsicContentSize.height)
            hint.frame = NSRect(
                x: trailing - RailMetrics.hintWidth, y: (rowHeight - hintHeight) / 2, width: RailMetrics.hintWidth,
                height: hintHeight)
            accessoryEnd -= RailMetrics.hintWidth
        }
        let accessoryWidth = accessory.fittingWidth
        accessory.frame = NSRect(
            x: accessoryEnd - accessoryWidth, y: (rowHeight - 16) / 2, width: accessoryWidth, height: 16)
        let textEnd = accessoryWidth > 0 ? accessory.frame.minX - 7 : accessoryEnd
        nameMaxX = textEnd
        let nameSize = name.intrinsicContentSize
        let nameHeight = ceil(nameSize.height)
        let nameY = (rowHeight - nameHeight) / 2
        if secondary.isHidden {
            name.frame = NSRect(x: x, y: nameY, width: max(0, textEnd - x), height: nameHeight)
        } else {
            let nameWidth = min(ceil(nameSize.width), max(0, textEnd - x))
            name.frame = NSRect(x: x, y: nameY, width: nameWidth, height: nameHeight)
            let branchX = name.frame.maxX + 7
            let branchHeight = ceil(secondary.intrinsicContentSize.height)
            secondary.frame = NSRect(
                x: branchX, y: (rowHeight - branchHeight) / 2, width: max(0, textEnd - branchX), height: branchHeight)
        }
    }

    @objc private func buttonPressed() {
        onButton?()
    }
}

/// Draws a row's accessory: the badge, a status word, a port label, a 6 pt dot or a ring (UX §3.1).
final class RailAccessoryView: NSView {
    private var accessory = RailAccessory.none
    private var selected = false

    override var isFlipped: Bool { true }

    /// `badgeIdentifier` is `rail.workspace.badge:<workspaceName>` on workspace rows: while the badge shows,
    /// the accessory is a static text element with that identifier and the count as its value (UX §3.1).
    func configure(_ accessory: RailAccessory, selected: Bool, badgeIdentifier: String? = nil) {
        if case .badge(let count) = accessory, let badgeIdentifier {
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityIdentifier(badgeIdentifier)
            setAccessibilityValue(String(count))
            setAccessibilityLabel(count == 1 ? "1 needs you" : "\(count) need you")
        } else {
            setAccessibilityElement(false)
            setAccessibilityIdentifier(nil)
        }
        guard accessory != self.accessory || selected != self.selected else { return }
        self.accessory = accessory
        self.selected = selected
        needsDisplay = true
    }

    var fittingWidth: CGFloat {
        switch accessory {
        case .none: 0
        case .dot, .ring: 6
        case .badge(let count): max(16, ceil(badgeText(count).size().width) + 8)
        case .word(let text, let tone): ceil(wordText(text, tone: tone).size().width)
        case .port(let label): ceil(wordText(label, tone: nil).size().width)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        switch accessory {
        case .none:
            break
        case .dot(let tone):
            Self.color(tone).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 6, y: midY - 3, width: 6, height: 6)).fill()
        case .ring:
            Tokens.stopped.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 5.25, y: midY - 2.25, width: 4.5, height: 4.5))
            ring.lineWidth = 1.5
            ring.stroke()
        case .badge(let count):
            Tokens.needsFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            let text = badgeText(count)
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: midY - size.height / 2))
        case .word(let word, let tone):
            let text = wordText(word, tone: tone)
            text.draw(at: NSPoint(x: bounds.maxX - text.size().width, y: midY - text.size().height / 2))
        case .port(let label):
            let text = wordText(label, tone: nil)
            text.draw(at: NSPoint(x: bounds.maxX - text.size().width, y: midY - text.size().height / 2))
        }
    }

    private func badgeText(_ count: Int) -> NSAttributedString {
        NSAttributedString(
            string: String(count),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: Tokens.onNeedsFill,
            ])
    }

    private func wordText(_ word: String, tone: RailTone?) -> NSAttributedString {
        let color: NSColor
        switch tone {
        case .failed: color = selected ? Tokens.failedTint : Tokens.failed
        case .needs: color = Tokens.needs
        default: color = selected ? Tokens.textSecondaryOnSelection : Tokens.textSecondary
        }
        return NSAttributedString(
            string: word, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: color])
    }

    private static func color(_ tone: RailTone) -> NSColor {
        switch tone {
        case .running: Tokens.running
        case .done: Tokens.done
        case .failed: Tokens.failed
        case .needs: Tokens.needs
        case .muted: Tokens.textSecondary
        }
    }
}
