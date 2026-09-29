import Foundation

/// The editor's git gutter marks (UX §6.1, R-ED-3): which buffer lines are added or modified against HEAD,
/// and where lines were deleted. Computed in the app with `CollectionDifference`, so unsaved edits show.
public struct GitGutterMarks: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case added
        case modified
    }

    /// A buffer line (0-based) → its mark.
    public var lines: [Int: Kind] = [:]
    /// Deletions, by the buffer line they sit above (0-based; `count` means after the last line).
    public var deletions: Set<Int> = []
    /// Contiguous runs of changes.
    public var hunks = 0

    public init() {}

    /// Diffs `text` against `base`, line by line.
    public init(base: String, text: String) {
        self.init(base: Self.lines(base), text: Self.lines(text))
    }

    init(base: [Substring], text: [Substring]) {
        let difference = text.difference(from: base)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var old = 0
        var new = 0
        while old < base.count || new < text.count {
            guard removed.contains(old) || inserted.contains(new) else {
                old += 1
                new += 1
                continue
            }
            var removedRun = 0
            while removed.contains(old) {
                removedRun += 1
                old += 1
            }
            var insertedRun = 0
            while inserted.contains(new) {
                insertedRun += 1
                new += 1
            }
            hunks += 1
            if insertedRun == 0 {
                deletions.insert(new)
            } else {
                let kind: Kind = removedRun == 0 ? .added : .modified
                for line in (new - insertedRun)..<new { lines[line] = kind }
            }
        }
    }

    /// Lines without their terminators; a trailing newline doesn't add an empty last line.
    static func lines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    /// The gutter's accessibility value, such as "2 changed hunks" or "no changes".
    public var summary: String {
        switch hunks {
        case 0: "no changes"
        case 1: "1 changed hunk"
        default: "\(hunks) changed hunks"
        }
    }
}
