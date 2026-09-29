import AppKit

/// Set Agent Command… (UX §3.5): a sheet titled "Agent command for Obsess" with the field `dialog.field`
/// (placeholder "claude"), a note on how the command runs, and [Save] (`dialog.confirm`, disabled while the
/// field is empty) and [Cancel] (`dialog.cancel`).
public enum AgentCommandSheet {
    /// Shows the sheet and returns the trimmed command, or nil when cancelled. Returns nil at once when
    /// another sheet is already up.
    public static func choose(on window: NSWindow, workspaceName: String, current: String?) async -> String? {
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return nil
        }
        let alert = NSAlert()
        alert.messageText = "Agent command for \(workspaceName)"
        alert.informativeText =
            "New agent tabs in this workspace run this command in your shell, so aliases like claude-work work."
        alert.alertStyle = .informational
        let confirm = alert.addButton(withTitle: "Save")
        let cancel = alert.addButton(withTitle: "Cancel")
        confirm.setAXIdentifier(AXID.dialogConfirm)
        cancel.setAXIdentifier(AXID.dialogCancel)
        alert.window.setAccessibilityIdentifier(AXID.dialog)
        alert.window.contentView?.setAccessibilityIdentifier(AXID.dialog)

        let form = CommandForm(command: current ?? "", confirm: confirm)
        alert.accessoryView = form
        alert.window.initialFirstResponder = form.field
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn ? form.command : nil)
            }
            alert.window.makeFirstResponder(form.field)
            form.field.selectText(nil)
            // NSAlert enables its buttons as it lays out the sheet.
            form.validate()
        }
    }
}

/// The sheet's accessory: the command field, which enables Save once it holds a command.
private final class CommandForm: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private weak var confirm: NSButton?

    init(command: String, confirm: NSButton) {
        self.confirm = confirm
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = command
        field.placeholderString = "claude"
        field.delegate = self
        field.setAXIdentifier(AXID.dialogField)
        field.setAccessibilityLabel("Agent command")
        field.frame = bounds
        addSubview(field)
        validate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CommandForm is built in code")
    }

    /// The trimmed command, or nil when the field is empty.
    var command: String? {
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func controlTextDidChange(_ notification: Notification) {
        validate()
    }

    func validate() {
        confirm?.isEnabled = command != nil
    }
}
