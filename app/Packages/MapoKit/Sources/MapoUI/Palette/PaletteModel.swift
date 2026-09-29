import Foundation
import MapoClient
import MapoProtocol
import Observation

/// What running a palette row does.
enum PaletteTarget {
    case tab(String)
    case workspace(String)
    case file(String)
    case command(Command)
}

/// The palette's sections, in the order an empty query shows them (UX §10).
enum PaletteSection: String {
    case attention = "Attention"
    case tabs = "Tabs"
    case workspaces = "Workspaces"
    case recentFiles = "Recent Files"
    case commands = "Commands"
}

struct PaletteRow: Identifiable {
    /// The row's position in display order, headers skipped: `palette.row:<id>`.
    let id: Int
    let section: PaletteSection
    let icon: String
    let title: String
    /// Offsets of the query's characters in `title`.
    let matched: [Int]
    let subtitle: String
    let trailing: String
    let target: PaletteTarget

    /// "{title}, {section}, {state or shortcut}" (UX §10).
    var accessibilityLabel: String {
        [title, section.rawValue, trailing].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct PaletteGroup: Identifiable {
    let section: PaletteSection
    let rows: [PaletteRow]
    var id: String { section.rawValue }
}

/// The palette's rows for a query, from the store's workspaces, tabs and recent files and the command
/// table. Rebuilt when the query changes.
@Observable
final class PaletteModel {
    private(set) var query = ""
    private(set) var groups: [PaletteGroup] = []
    private(set) var rows: [PaletteRow] = []
    var selection = 0

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let commands: () -> [Command]

    static let maximumRows = 50
    private static let perSection = 6
    private static let recentOnEmpty = 5

    init(store: AppStore, commands: @escaping () -> [Command]) {
        self.store = store
        self.commands = commands
    }

    var selectedRow: PaletteRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func update(query: String) {
        self.query = query
        rebuild()
    }

    /// Moves the selection, wrapping at both ends.
    func move(by offset: Int) {
        guard !rows.isEmpty else { return }
        selection = ((selection + offset) % rows.count + rows.count) % rows.count
    }

    // MARK: Building

    private struct Candidate {
        let section: PaletteSection
        let icon: String
        let title: String
        /// Other text the query may match, such as a tab's stable name or a file's full path.
        let keys: [String]
        let subtitle: String
        let trailing: String
        let target: PaletteTarget
    }

    func rebuild() {
        let text = query.trimmingCharacters(in: .whitespaces)
        var sections: [(PaletteSection, [(Candidate, FuzzyMatch?)])] = []
        if text.hasPrefix(">") {
            let needle = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            sections = [(.commands, ranked(commandCandidates(), needle, limit: Self.maximumRows))]
        } else if text.isEmpty {
            let attention = tabCandidates(section: .attention).filter { candidate in
                if case .tab(let id) = candidate.target { return store.tabs[id]?.state == .needsYou }
                return false
            }
            let active = store.activeWorkspaceId
            let tabs = tabCandidates(section: .tabs).filter { candidate in
                if case .tab(let id) = candidate.target { return store.tabs[id]?.workspaceId == active }
                return false
            }
            sections = [
                (.attention, attention.map { ($0, nil) }),
                (.tabs, tabs.map { ($0, nil) }),
                (.recentFiles, fileCandidates().prefix(Self.recentOnEmpty).map { ($0, nil) }),
                (.workspaces, workspaceCandidates().map { ($0, nil) }),
            ]
        } else {
            sections = [
                (.tabs, ranked(tabCandidates(section: .tabs), text, limit: Self.perSection)),
                (.workspaces, ranked(workspaceCandidates(), text, limit: Self.perSection)),
                (.recentFiles, ranked(fileCandidates(), text, limit: Self.perSection)),
                (.commands, ranked(commandCandidates(), text, limit: Self.perSection)),
            ]
        }

        var built: [PaletteGroup] = []
        var all: [PaletteRow] = []
        for (section, entries) in sections {
            var rows: [PaletteRow] = []
            for (candidate, match) in entries where all.count + rows.count < Self.maximumRows {
                rows.append(
                    PaletteRow(
                        id: all.count + rows.count, section: section, icon: candidate.icon, title: candidate.title,
                        matched: match?.indices ?? [], subtitle: candidate.subtitle, trailing: candidate.trailing,
                        target: candidate.target))
            }
            guard !rows.isEmpty else { continue }
            built.append(PaletteGroup(section: section, rows: rows))
            all += rows
        }
        groups = built
        rows = all
        selection = 0
    }

    /// Candidates that match, best first; ties keep source order. Only a match on the title highlights.
    private func ranked(_ candidates: [Candidate], _ query: String, limit: Int) -> [(Candidate, FuzzyMatch?)] {
        var scored: [(offset: Int, candidate: Candidate, score: Int, title: FuzzyMatch?)] = []
        for (offset, candidate) in candidates.enumerated() {
            let title = FuzzyMatch.match(query, in: candidate.title)
            let best = ([title] + candidate.keys.map { FuzzyMatch.match(query, in: $0) }).compactMap { $0 }
                .map(\.score).max()
            guard let best else { continue }
            scored.append((offset, candidate, best, title))
        }
        scored.sort { ($0.score, -$0.offset) > ($1.score, -$1.offset) }
        return scored.prefix(limit).map { ($0.candidate, $0.title) }
    }

    /// Tabs of every workspace, the active workspace first, each in rail order.
    private func tabCandidates(section: PaletteSection) -> [Candidate] {
        var workspaces = store.workspaces
        if let index = workspaces.firstIndex(where: { $0.id == store.activeWorkspaceId }) {
            workspaces.insert(workspaces.remove(at: index), at: 0)
        }
        return workspaces.flatMap { workspace in
            store.tabs(inWorkspace: workspace.id).map { tab in
                let row = RailModel.tabRow(tab, workspace: workspace, selected: false)
                return Candidate(
                    section: section, icon: tab.isAgent ? "sparkle" : "terminal", title: row.text,
                    keys: row.text == tab.name ? [] : [tab.name], subtitle: workspace.name,
                    trailing: Self.stateWord(label: row.label ?? "", title: row.text), target: .tab(tab.id))
            }
        }
    }

    /// The rail's state phrase ("needs you", "serving on port 4000"), capitalized.
    private static func stateWord(label: String, title: String) -> String {
        guard label.count > title.count + 2, label.hasPrefix(title + ", ") else { return "" }
        let phrase = label.dropFirst(title.count + 2)
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    private func workspaceCandidates() -> [Candidate] {
        store.workspaces.map { workspace in
            let tabs = workspace.tabCount == 1 ? "1 tab" : "\(workspace.tabCount) tabs"
            return Candidate(
                section: .workspaces, icon: "square.stack", title: workspace.name, keys: [],
                subtitle: workspace.summary.isEmpty ? tabs : workspace.summary,
                trailing: workspace.attentionCount > 0 ? "\(workspace.attentionCount)" : "",
                target: .workspace(workspace.id))
        }
    }

    /// Recent files of every pane (layouts' `recentFiles`), the active workspace's first, without repeats.
    private func fileCandidates() -> [Candidate] {
        var layouts = store.workspaces.compactMap { store.layouts[$0.id] }
        if let index = layouts.firstIndex(where: { $0.workspaceId == store.activeWorkspaceId }) {
            layouts.insert(layouts.remove(at: index), at: 0)
        }
        var seen = Set<String>()
        var result: [Candidate] = []
        for layout in layouts {
            for path in Self.recentFiles(layout.root) where seen.insert(path).inserted {
                let url = URL(fileURLWithPath: path)
                result.append(
                    Candidate(
                        section: .recentFiles, icon: "doc", title: url.lastPathComponent, keys: [path],
                        subtitle: RailModel.abbreviateHome(url.deletingLastPathComponent().path), trailing: "",
                        target: .file(path)))
            }
        }
        return result
    }

    private static func recentFiles(_ node: LayoutNode) -> [String] {
        switch node {
        case .pane(_, _, let recentFiles): recentFiles
        case .split(_, _, _, let children): children.flatMap(recentFiles)
        }
    }

    private func commandCandidates() -> [Candidate] {
        commands().map { command in
            Candidate(
                section: .commands, icon: "command", title: command.paletteTitle ?? command.title, keys: [],
                subtitle: "", trailing: command.shortcut?.display ?? "", target: .command(command))
        }
    }
}
