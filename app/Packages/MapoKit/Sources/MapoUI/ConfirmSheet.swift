import AppKit

/// A confirmation sheet on a window (UX §3.5, PA-35): `dialog`, with `dialog.confirm` and `dialog.cancel`.
/// `ui.tree` includes attached sheets, so drives press the buttons by identifier.
public enum ConfirmSheet {
    /// Shows the sheet and returns true when the person confirmed. A destructive confirm sets
    /// `hasDestructiveAction`. Returns false at once when another sheet is already up.
    public static func confirm(
        on window: NSWindow, title: String, message: String, confirm: String, destructive: Bool = true
    ) async -> Bool {
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return false
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let confirmButton = alert.addButton(withTitle: confirm)
        let cancelButton = alert.addButton(withTitle: "Cancel")
        confirmButton.hasDestructiveAction = destructive
        confirmButton.setAXIdentifier(AXID.dialogConfirm)
        cancelButton.setAXIdentifier(AXID.dialogCancel)
        alert.window.setAccessibilityIdentifier(AXID.dialog)
        alert.window.contentView?.setAccessibilityIdentifier(AXID.dialog)
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn
    }
}
