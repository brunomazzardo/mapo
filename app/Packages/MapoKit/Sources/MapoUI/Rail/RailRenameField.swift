import AppKit

/// The inline rename field (`rail.rename`, UX §3.4): the row's name turns into a text field in the same
/// font, with a 1 pt `accent` border, radius 4 and the text selected. It validates while typing; Return
/// commits, Esc cancels, and clicking away commits a valid change and cancels anything else.
final class RailRenameField: NSTextField, NSTextFieldDelegate {
    /// Why the current text can't be used, or nil when it can.
    var validate: (String) -> String? = { _ in nil }
    /// Called with the new name on Return, or on clicking away with a valid change.
    var onCommit: (String) -> Void = { _ in }
    /// Called on Esc, an unchanged value, or clicking away while invalid.
    var onCancel: () -> Void = {}

    let rowKey: String
    private let original: String
    private var problem: String?
    /// Set once the field has committed or cancelled, so ending the edit doesn't act twice.
    private var finished = false

    init(rowKey: String, text: String, font: NSFont?) {
        self.rowKey = rowKey
        self.original = text
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        isBordered = false
        isBezeled = false
        drawsBackground = true
        backgroundColor = Tokens.pane
        textColor = Tokens.textPrimary
        focusRingType = .none
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        delegate = self
        setAXIdentifier(AXID.railRename)
        setAccessibilityLabel("Name")
        showProblem(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RailRenameField is built in code")
    }

    /// Takes keyboard focus and selects the whole name.
    func begin() {
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    /// Shows a rejection from the daemon and keeps the field open (UX §3.4).
    func reject(_ message: String) {
        finished = false
        showProblem(message)
        if window?.firstResponder !== currentEditor() { begin() }
    }

    private func showProblem(_ message: String?) {
        problem = message
        layer?.borderColor = (message == nil ? Tokens.accent : Tokens.failed).cgColor
        toolTip = message
    }

    private var trimmed: String {
        stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitIfValid() {
        let name = trimmed
        if name == original {
            cancel()
            return
        }
        showProblem(validate(name))
        guard problem == nil else { return }
        finished = true
        onCommit(name)
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        let name = trimmed
        showProblem(name == original ? nil : validate(name))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return does nothing while the name is invalid.
            commitIfValid()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !finished else { return }
        let name = trimmed
        if name != original, validate(name) == nil {
            finished = true
            onCommit(name)
        } else {
            cancel()
        }
    }
}
