import AppKit

/// One `FileEditorView` per absolute path, for the whole app. A card takes the editor for its file the way it
/// takes a terminal host, so the buffer survives workspace switches (the containers stay cached), picking
/// another recent file, and closing the pane: a dirty editor is never dropped (R-ED-5).
public final class EditorRegistry {
    public var theme: EditorTheme
    /// `<dataDir>/recovery`; nil until the app knows its instance.
    public var recoveryDirectory: URL?
    /// Called when any editor's dirty state changes.
    public var onDirtyChange: (() -> Void)?

    private var editors: [String: FileEditorView] = [:]

    public init(theme: EditorTheme, recoveryDirectory: URL? = nil) {
        self.theme = theme
        self.recoveryDirectory = recoveryDirectory
    }

    /// The editor for `path`, reading the file on first use.
    public func editor(for path: String) -> FileEditorView {
        if let editor = editors[path] { return editor }
        let editor = FileEditorView(path: path, theme: theme, recoveryDirectory: recoveryDirectory)
        editor.onDirtyChange = { [weak self] _ in self?.onDirtyChange?() }
        editors[path] = editor
        return editor
    }

    public func existing(for path: String) -> FileEditorView? {
        editors[path]
    }

    /// A card stopped showing `path`: drop the editor unless it is dirty or another card shows it.
    public func release(_ path: String) {
        guard let editor = editors[path], !editor.isDirty, editor.superview == nil else { return }
        editor.close()
        editors[path] = nil
    }

    /// Editors with unsaved changes, by file name.
    public var dirtyEditors: [FileEditorView] {
        editors.values.filter(\.isDirty).sorted { $0.name < $1.name }
    }

    /// Saves every dirty editor; returns the ones that failed (their bars say why).
    @discardableResult
    public func saveAll() -> [FileEditorView] {
        for editor in dirtyEditors { editor.save() }
        return dirtyEditors
    }

    /// Don't Save at quit: drops recovery copies of every dirty buffer.
    public func abandonAll() {
        for editor in dirtyEditors { editor.abandon() }
    }
}
