import Foundation

/// `fs.list` params and result (PROTOCOL §6.5).
nonisolated struct FsPathParams: Encodable, Sendable {
    let path: String
}

nonisolated struct FsListing: Decodable, Sendable {
    struct Entry: Decodable, Hashable, Sendable {
        var name: String
        /// `file`, `dir` or `symlink` (a broken link).
        var kind: String
        /// `M`, `A`, `D`, `R`, `?` (untracked) or `U` (conflicted).
        var git: String?
    }

    struct Repo: Decodable, Hashable, Sendable {
        var root: String
        var branch: String?
    }

    var path: String
    /// `ready`, `empty`, `missing` or `unreadable`.
    var state: String
    var hiddenByExclude: Int
    var entries: [Entry]
    var repo: Repo?
}

/// What the Files segment shows instead of the tree (UX §5.2 states, R-FS-5).
nonisolated enum FilesState: String, Sendable {
    case loading
    case ready
    case empty
    case missing
    case unreadable
    case noTerminal = "no-terminal"
}

/// A row of the Files tree. Nodes keep their identity across refreshes so the outline keeps expansion,
/// selection and scroll.
final class FileNode: NSObject {
    let name: String
    let path: String
    /// Relative to the Files root, `/`-separated.
    let relativePath: String
    let isFolder: Bool
    let depth: Int
    var git: String?
    /// Nil until the folder is listed.
    var children: [FileNode]?
    var isLoading = false

    init(name: String, path: String, relativePath: String, isFolder: Bool, depth: Int, git: String?) {
        self.name = name
        self.path = path
        self.relativePath = relativePath
        self.isFolder = isFolder
        self.depth = depth
        self.git = git
    }

    /// The entries as nodes, reusing `existing` nodes of the same name and kind (with their children).
    static func merge(
        _ entries: [FsListing.Entry], into existing: [FileNode]?, parentPath: String, parentRelative: String,
        depth: Int
    ) -> [FileNode] {
        let old = Dictionary(
            (existing ?? []).map { ("\($0.isFolder ? "d" : "f")/\($0.name)", $0) },
            uniquingKeysWith: { first, _ in first })
        return entries.map { entry in
            let isFolder = entry.kind == "dir"
            if let node = old["\(isFolder ? "d" : "f")/\(entry.name)"] {
                node.git = entry.git
                return node
            }
            let relative = parentRelative.isEmpty ? entry.name : "\(parentRelative)/\(entry.name)"
            let path = parentPath.hasSuffix("/") ? parentPath + entry.name : "\(parentPath)/\(entry.name)"
            return FileNode(
                name: entry.name, path: path, relativePath: relative, isFolder: isFolder, depth: depth, git: entry.git)
        }
    }
}

enum FilesText {
    /// `path` with the home folder written `~`.
    static func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The letter shown for a `git` value (UX §5.2): untracked reads U, conflicted reads C.
    static func letter(_ git: String?) -> String? {
        switch git {
        case "?": "U"
        case "U": "C"
        case let value?: value
        case nil: nil
        }
    }

    /// A row's VoiceOver label: name, kind and git status, such as "src, folder, expanded, modified".
    static func rowLabel(_ node: FileNode, expanded: Bool) -> String {
        var label = node.name
        if node.isFolder { label += expanded ? ", folder, expanded" : ", folder" }
        if let spoken = spoken(node.git) { label += ", \(spoken)" }
        return label
    }

    /// The spoken status for a `git` value.
    static func spoken(_ git: String?) -> String? {
        switch git {
        case "M": "modified"
        case "A": "added"
        case "D": "deleted"
        case "R": "renamed"
        case "?": "untracked"
        case "U": "conflicted"
        default: nil
        }
    }

    /// `(title, body)` for a state, or nil for `ready`.
    static func copy(_ state: FilesState, path: String, hiddenByExclude: Int) -> (String, String)? {
        let shown = tildePath(path)
        switch state {
        case .ready: return nil
        case .loading: return ("Loading…", "")
        case .empty:
            if hiddenByExclude > 0 {
                return ("Nothing to show", "Exclude rules hide every item in \(shown).")
            }
            return ("Empty folder", "\(shown) has no files.")
        case .missing:
            return (
                "Folder not found", "\(shown) was moved or deleted. Restore it and retry, or cd somewhere else."
            )
        case .unreadable:
            return ("Can't read this folder", "Check the permissions of \(shown) in Finder, then retry.")
        case .noTerminal:
            return ("No terminal focused", "Focus a terminal to see its folder here.")
        }
    }
}
