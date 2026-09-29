import AppKit

/// New Tab in Folder… (⌥⌘T, UX §3.5): a sheet titled "New tab in folder" with the path field
/// `dialog.field`, which starts as the focused tab's `~` folder, fully selected, and [New Tab]
/// (`dialog.confirm`) and [Cancel] (`dialog.cancel`). A path that isn't a folder disables New Tab and says so.
public enum FolderSheet {
    /// Shows the sheet and returns the chosen folder as an absolute path, or nil when cancelled. Returns nil
    /// at once when another sheet is already up.
    public static func choose(on window: NSWindow, initialFolder: String) async -> String? {
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return nil
        }
        let alert = NSAlert()
        alert.messageText = "New tab in folder"
        alert.alertStyle = .informational
        let confirm = alert.addButton(withTitle: "New Tab")
        let cancel = alert.addButton(withTitle: "Cancel")
        confirm.setAXIdentifier(AXID.dialogConfirm)
        cancel.setAXIdentifier(AXID.dialogCancel)
        alert.window.setAccessibilityIdentifier(AXID.dialog)
        alert.window.contentView?.setAccessibilityIdentifier(AXID.dialog)

        let form = FolderForm(path: RailModel.abbreviateHome(initialFolder), confirm: confirm)
        alert.accessoryView = form
        alert.window.initialFirstResponder = form.field
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn ? form.folder : nil)
            }
            // Fully selected, so typing replaces it (PA-28).
            alert.window.makeFirstResponder(form.field)
            form.field.selectText(nil)
        }
    }

    static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return (trimmed as NSString).expandingTildeInPath
    }
}

/// The sheet's accessory: the path field and the line that explains a bad path.
private final class FolderForm: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let problem = NSTextField(labelWithString: "")
    private weak var confirm: NSButton?

    init(path: String, confirm: NSButton) {
        self.confirm = confirm
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 46))
        field.stringValue = path
        field.placeholderString = "~/code/project"
        field.delegate = self
        field.setAXIdentifier(AXID.dialogField)
        field.setAccessibilityLabel("Folder")
        field.frame = NSRect(x: 0, y: 22, width: 320, height: 24)
        problem.font = .systemFont(ofSize: 11)
        problem.textColor = .secondaryLabelColor
        problem.frame = NSRect(x: 0, y: 0, width: 320, height: 16)
        addSubview(field)
        addSubview(problem)
        validate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FolderForm is built in code")
    }

    /// The field's folder when it names one.
    var folder: String? {
        let path = FolderSheet.expand(field.stringValue)
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return path
    }

    func controlTextDidChange(_ notification: Notification) {
        validate()
    }

    /// "No folder at ~/code/x." disables New Tab while typing (UX §3.5).
    private func validate() {
        let ok = folder != nil
        confirm?.isEnabled = ok
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        problem.stringValue = ok || text.isEmpty ? "" : "No folder at \(text)."
        field.setAccessibilityValueDescription(problem.stringValue.isEmpty ? nil : problem.stringValue)
    }
}
