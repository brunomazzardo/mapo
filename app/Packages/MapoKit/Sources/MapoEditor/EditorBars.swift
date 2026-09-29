import AppKit

/// A bar at the top of the editor body (UX §6.2): 32 tall, padding 0 12, `control` fill, 12 pt text, buttons
/// at the right. Its AX value names the message, such as `changedOnDisk`, so drives can read it.
final class EditorBarView: NSView {
    static let height: CGFloat = 32

    struct Button {
        var title: String
        var identifier: String
        var isDefault = false
        var action: () -> Void
    }

    private let message = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let rule = NSView()
    private var actions: [() -> Void] = []
    var theme = EditorTheme.system {
        didSet { applyColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        message.font = .systemFont(ofSize: 12)
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        rule.wantsLayer = true
        for view in [message, buttons, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorBarView is built in code")
    }

    func show(kind: String, text: String, buttons specs: [Button]) {
        message.stringValue = text
        setAccessibilityLabel(text)
        setAccessibilityValue(kind)
        for view in buttons.arrangedSubviews { view.removeFromSuperview() }
        actions = specs.map(\.action)
        for (index, spec) in specs.enumerated() {
            let button = NSButton(title: spec.title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: spec.isDefault ? .semibold : .regular)
            if spec.isDefault { button.tintProminence = .primary }
            button.setAccessibilityIdentifier(spec.identifier)
            button.cell?.setAccessibilityIdentifier(spec.identifier)
            buttons.addArrangedSubview(button)
        }
    }

    /// The first button, for keyboard focus on a body that has nothing else (a binary file).
    var firstButton: NSButton? {
        buttons.arrangedSubviews.first as? NSButton
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        message.textColor = theme.barText
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = theme.barFill.cgColor
            rule.layer?.backgroundColor = theme.divider.cgColor
        }
    }
}

/// The Go to Line bar (⌘L): "Go to Line" and a field taking `42` or `42:7`. Return jumps and centers the
/// line; Escape closes. The palette's line mode (UX §10) calls the same `goToLine` when it lands.
final class GoToLineBar: NSView, NSTextFieldDelegate {
    var onGo: ((Int, Int?) -> Void)?
    var onCancel: (() -> Void)?
    let field = NSTextField()
    private let label = NSTextField(labelWithString: "Go to Line")
    private let rule = NSView()
    var theme = EditorTheme.system {
        didSet { applyColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "Line or line:column"
        field.controlSize = .small
        field.delegate = self
        field.focusRingType = .none
        rule.wantsLayer = true
        for view in [label, field, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 140),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GoToLineBar is built in code")
    }

    /// `42` → (42, nil); `42:7` → (42, 7); anything else → nil.
    static func parse(_ text: String) -> (line: Int, column: Int?)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let line = Int(parts[0]), line > 0 else { return nil }
        if parts.count == 2 {
            guard let column = Int(parts[1]), column > 0 else { return nil }
            return (line, column)
        }
        return (line, nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let target = Self.parse(field.stringValue) {
                onGo?(target.line, target.column)
            } else {
                NSSound.beep()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        label.textColor = theme.barText
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = theme.barFill.cgColor
            rule.layer?.backgroundColor = theme.divider.cgColor
        }
    }
}
