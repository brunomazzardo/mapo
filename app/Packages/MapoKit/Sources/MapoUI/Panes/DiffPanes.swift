import AppKit
import MapoClient
import MapoEditor
import MapoProtocol

/// The app's diff panes (UX §6.3, R-GIT-2): one `DiffView` per file, reading `git.diff` and reloading when
/// its repository changes (`fs.changed`, `git.changed`). Open File opens the file in the editor.
enum DiffPanes {
    private static var client: MapoClient?
    private static var views: [String: DiffView] = [:]

    /// Called once with the app's client; also gives the editors their base text for the gutter.
    static func configure(client: MapoClient) {
        guard self.client == nil else { return }
        self.client = client
        FileEditors.registry.baseTextLoader = { [weak client] path in
            guard let client else { return nil }
            return try? await client.gitBaseText(path: path)
        }
        client.addEventListener { event in
            switch event.payload {
            case .gitChanged(let change):
                FileEditors.registry.refreshBaseTexts(under: change.root)
                reload(under: change.root)
            case .fsChanged(let change):
                reload(under: change.root)
            default:
                break
            }
        }
    }

    static var colors: DiffColors {
        DiffColors(
            context: Tokens.textBody, hunk: Tokens.diffHunk, hunkBackground: Tokens.diffHunkBg,
            addedText: Tokens.diffAddedText, addedBackground: Tokens.diffAddedBg,
            removedText: Tokens.diffRemovedText, removedBackground: Tokens.diffRemovedBg)
    }

    /// The view for `ref`, loading the diff on first use.
    static func view(for ref: DiffRef) -> DiffView {
        if let view = views[ref.path], view.root == ref.root { return view }
        let view = DiffView(root: ref.root, path: ref.path, theme: FileEditors.theme, colors: colors)
        view.loader = { [root = ref.root, path = ref.path] in
            guard let client else { throw MapoClient.ClientError.notConnected }
            return try await client.gitDiff(root: root, path: path)
        }
        view.onOpenFile = { [path = ref.path] in
            guard let client else { return }
            Task {
                do {
                    let opened = try await client.openFile(path: path)
                    FileEditors.focusWhenShown(opened.path)
                } catch {
                    MapoLog.shared.info("diff: open \(path): file.open failed: \(error)")
                    NSSound.beep()
                }
            }
        }
        views[ref.path] = view
        view.reload()
        return view
    }

    /// A card stopped showing the diff of `path`.
    static func release(_ path: String) {
        guard let view = views[path], view.superview == nil else { return }
        views[path] = nil
    }

    /// Reloads shown diffs whose file is under `folder`.
    private static func reload(under folder: String) {
        for view in views.values where view.path.hasPrefix(folder + "/") || view.root == folder {
            view.reload()
        }
    }
}
