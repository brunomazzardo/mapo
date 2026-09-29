import AppKit
import MapoEditor
import MapoProtocol

/// The app's file editors (UX §6, PLAN T1.6): one `EditorRegistry` drawn with Mapo's tokens, the quit
/// confirmation for unsaved files, the window's edited dot, and focus for a file someone just opened.
public enum FileEditors {
    /// Every file pane's editor, keyed by absolute path.
    public static let registry: EditorRegistry = {
        let registry = EditorRegistry(theme: theme)
        registry.onDirtyChange = { updateDocumentEdited() }
        return registry
    }()

    /// Recovery copies go to `<dataDir>/recovery/` (R-ED-5).
    public static func configure(dataDirectory: URL) {
        registry.recoveryDirectory = dataDirectory.appending(path: "recovery", directoryHint: .isDirectory)
    }

    static var theme: EditorTheme {
        EditorTheme(
            background: Tokens.pane, text: Tokens.textBody, lineNumber: Tokens.lineNumber,
            currentLineNumber: Tokens.textBody, selection: Tokens.editorSelection,
            currentLine: Tokens.editorCurrentLine, barFill: Tokens.control, barText: Tokens.textBody,
            divider: Tokens.paneDivider, checker: Tokens.control,
            syntax: [
                .keyword: Tokens.syntaxKeyword, .string: Tokens.syntaxString, .function: Tokens.syntaxFunction,
                .type: Tokens.syntaxType, .number: Tokens.syntaxNumber, .punctuation: Tokens.syntaxPunctuation,
                .comment: Tokens.syntaxComment,
            ], gitAdded: Tokens.done, gitModified: Tokens.running, gitDeleted: Tokens.failed)
    }

    /// `ui.snapshot`'s `editors` field: each open editor's language and its last highlight pass (R-ED-2), so
    /// drives can check highlighting without pixels.
    public static func automationModel() -> JSONValue {
        .array(
            registry.all.map { editor in
                var highlight = JSONValue.null
                if let summary = editor.highlight {
                    let kinds = summary.kinds.map { ($0.key.rawValue, JSONValue.number(Double($0.value))) }
                    highlight = .object([
                        "engine": .string(summary.engine), "length": .number(Double(summary.length)),
                        "kinds": .object(Dictionary(uniqueKeysWithValues: kinds)),
                    ])
                }
                return .object([
                    "path": .string(editor.path),
                    "language": editor.language.map { .string($0.rawValue) } ?? .null,
                    "highlight": highlight,
                ])
            })
    }

    // MARK: Focus

    /// A file the person just opened from the app (the Files inspector, the palette): its editor takes
    /// keyboard focus once its card shows it, even if the inspector has focus now (REQUIREMENTS §8.3).
    public static func focusWhenShown(_ path: String) {
        pendingFocus = path
        focusPendingIfShown()
    }

    private static var pendingFocus: String?

    /// Called after the panes render.
    static func focusPendingIfShown() {
        guard let path = pendingFocus, let editor = registry.existing(for: path), editor.window != nil,
            !editor.isHiddenOrHasHiddenAncestor
        else { return }
        pendingFocus = nil
        editor.focus()
    }

    // MARK: Edited state and quitting

    /// The red close button's dot follows unsaved files (UX §6.1).
    static func updateDocumentEdited() {
        let dirty = !registry.dirtyEditors.isEmpty
        for window in NSApp.windows where window.contentViewController != nil {
            window.isDocumentEdited = dirty
        }
    }

    /// `applicationShouldTerminate`: with unsaved files, asks in a sheet on `window` (UX §6.2) and answers
    /// `NSApp.reply(toApplicationShouldTerminate:)` later: [Save All] (`dialog.confirm`), [Don't Save]
    /// (`dialog.discard`), [Cancel] (`dialog.cancel`). A failed save cancels the quit and shows its bar.
    public static func shouldTerminate(window: NSWindow?) -> NSApplication.TerminateReply {
        let dirty = registry.dirtyEditors
        guard !dirty.isEmpty else { return .terminateNow }
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return .terminateCancel
        }
        let alert = NSAlert()
        alert.messageText =
            dirty.count == 1
            ? "Save changes to \"\(dirty[0].name)\" before quitting?"
            : "Save changes to \(dirty.count) files before quitting?"
        alert.informativeText = "Your changes are lost if you don't save them."
        alert.alertStyle = .warning
        let save = alert.addButton(withTitle: "Save All")
        let discard = alert.addButton(withTitle: "Don't Save")
        let cancel = alert.addButton(withTitle: "Cancel")
        save.setAXIdentifier(AXID.dialogConfirm)
        discard.setAXIdentifier(AXID.dialogDiscard)
        cancel.setAXIdentifier(AXID.dialogCancel)
        discard.hasDestructiveAction = true
        alert.window.setAccessibilityIdentifier(AXID.dialog)
        alert.window.contentView?.setAccessibilityIdentifier(AXID.dialog)
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn:
                    let failed = registry.saveAll()
                    NSApp.reply(toApplicationShouldTerminate: failed.isEmpty)
                case .alertSecondButtonReturn:
                    registry.abandonAll()
                    NSApp.reply(toApplicationShouldTerminate: true)
                default:
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
            }
        }
        return .terminateLater
    }

    /// Closing a dirty file pane asks first (UX §4.2): true when the pane may close. Save writes the file;
    /// Don't Save drops the buffer and its recovery copy.
    static func confirmClose(path: String, window: NSWindow?) async -> Bool {
        guard let editor = registry.existing(for: path), editor.isDirty else { return true }
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(editor.name)\"?"
        alert.informativeText = "Your changes are lost if you don't save them."
        alert.alertStyle = .warning
        let save = alert.addButton(withTitle: "Save")
        let discard = alert.addButton(withTitle: "Don't Save")
        let cancel = alert.addButton(withTitle: "Cancel")
        save.setAXIdentifier(AXID.dialogConfirm)
        discard.setAXIdentifier(AXID.dialogDiscard)
        cancel.setAXIdentifier(AXID.dialogCancel)
        alert.window.setAccessibilityIdentifier(AXID.dialog)
        alert.window.contentView?.setAccessibilityIdentifier(AXID.dialog)
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn:
            editor.save()
            return !editor.isDirty
        case .alertSecondButtonReturn:
            editor.revertToSaved()
            return true
        default:
            return false
        }
    }
}
