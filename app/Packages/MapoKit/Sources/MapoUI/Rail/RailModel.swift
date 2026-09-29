import Foundation
import MapoClient
import MapoProtocol
import Observation

/// Whether the hold-⌘ hints show (UX §3.3). The rail's `flagsChanged` monitor sets it; the rail rows and
/// `model.rail` read it.
@Observable
final class RailHints {
    static let shared = RailHints()
    var visible = false
}

/// What a rail row shows at its trailing edge (UX §3.1, §3.8).
enum RailAccessory: Equatable {
    case none
    /// The workspace badge: tabs that need you.
    case badge(Int)
    /// "Needs you", "Failed" or "Couldn't start".
    case word(String, RailTone)
    /// ":4000" or ":4000 +1".
    case port(String)
    case dot(RailTone)
    case ring

    /// The snapshot form of UX §3.8, such as `badge:1`, `word:Failed` or `dot:running`.
    var snapshotValue: String? {
        switch self {
        case .none: nil
        case .badge(let count): "badge:\(count)"
        case .word(let text, _): "word:\(text)"
        case .port(let label): "port:\(label)"
        case .dot(let tone): "dot:\(tone.rawValue)"
        case .ring: "ring:stopped"
        }
    }
}

/// The status colors of UX §9.1.
enum RailTone: String, Equatable {
    case running, done, failed, needs, muted
}

enum RailIcon: String, Equatable {
    case agent, shell, server
}

/// One row of the basic S2 rail, derived from the store. Equal rows render identically, which is how the
/// rail reloads only the rows that changed.
struct RailRow: Equatable {
    enum Kind: Equatable {
        case header
        case workspace(expanded: Bool, active: Bool)
        case tab(icon: RailIcon, selected: Bool)
        case noTabs
        case noWorkspaces
        case newWorkspaceButton
        /// The 6 pt gap after the expanded workspace's last row. A row of its own, so tab rows stay 24 pt.
        case gap
    }

    /// Stable across renders: `workspace:<id>`, `tab:<id>`, and so on.
    var key: String
    var kind: Kind
    /// The workspace or tab id.
    var modelId: String?
    /// The workspace a tab or "No tabs" row belongs to.
    var workspaceId: String?
    var text: String
    var secondaryText: String?
    var state: TabState = .idle
    var accessory: RailAccessory = .none
    var tint: RailTone?
    var identifier: String?
    var label: String?
    var help: String?
    var tooltip: String?
    /// "⌘1" to "⌘9" while ⌘ is held, on the active workspace's first nine tab rows (UX §3.3).
    var hint: String?
    var contentHeight: Double {
        switch kind {
        case .workspace: 26
        case .newWorkspaceButton: 28
        case .gap: 6
        default: 24
        }
    }

    var height: Double { contentHeight }

    var isSelected: Bool {
        if case .tab(_, let selected) = kind { return selected }
        return false
    }

    var isWorkspace: Bool {
        if case .workspace = kind { return true }
        return false
    }

    var isTab: Bool {
        if case .tab = kind { return true }
        return false
    }

    var isInteractive: Bool {
        switch kind {
        case .workspace, .tab: true
        default: false
        }
    }
}

enum RailModel {
    /// The rows in display order: the header, every workspace, and the tabs of the active one only.
    static func rows(_ store: AppStore) -> [RailRow] {
        var rows = [RailRow(key: "header", kind: .header, text: "Workspaces")]
        guard store.hasSnapshot else { return rows }
        let hints = RailHints.shared.visible
        if store.workspaces.isEmpty {
            rows.append(RailRow(key: "no-workspaces", kind: .noWorkspaces, text: "No workspaces"))
            rows.append(RailRow(key: "new-workspace", kind: .newWorkspaceButton, text: "New Workspace"))
            return rows
        }
        for workspace in store.workspaces {
            let active = workspace.id == store.activeWorkspaceId
            rows.append(workspaceRow(workspace, active: active))
            guard active else { continue }
            let tabs = store.tabs(inWorkspace: workspace.id)
            let selectedId = store.focusedTabId(inWorkspace: workspace.id)
            if tabs.isEmpty {
                rows.append(
                    RailRow(
                        key: "no-tabs:\(workspace.id)", kind: .noTabs, workspaceId: workspace.id, text: "No tabs"))
            }
            for (index, tab) in tabs.enumerated() {
                var row = tabRow(tab, workspace: workspace, selected: tab.id == selectedId)
                if hints, index < 9 { row.hint = "⌘\(index + 1)" }
                rows.append(row)
            }
            rows.append(RailRow(key: "gap:\(workspace.id)", kind: .gap, text: ""))
        }
        return rows
    }

    static func workspaceRow(_ workspace: WorkspaceSummary, active: Bool) -> RailRow {
        var accessory = RailAccessory.none
        if workspace.attentionCount > 0 {
            accessory = .badge(workspace.attentionCount)
        } else if !active {
            switch workspace.state {
            case .failed: accessory = .dot(.failed)
            case .running: accessory = .dot(.running)
            case .done: accessory = .dot(.done)
            default: break
            }
        }
        var label = workspace.name
        if let branch = workspace.branch, !branch.isEmpty { label += ", branch \(branch)" }
        if workspace.attentionCount == 1 {
            label += ", 1 needs you"
        } else if workspace.attentionCount > 1 {
            label += ", \(workspace.attentionCount) need you"
        } else if workspace.state != .idle {
            label += ", \(stateWord(workspace.state, label: workspace.stateLabel))"
        }
        let tooltip = workspace.summary.isEmpty ? tabCount(workspace.tabCount) : workspace.summary
        return RailRow(
            key: "workspace:\(workspace.id)", kind: .workspace(expanded: active, active: active),
            modelId: workspace.id, text: workspace.name, secondaryText: workspace.branch, state: workspace.state,
            accessory: accessory, identifier: AXID.railWorkspace(workspace.name), label: label, tooltip: tooltip)
    }

    static func tabRow(_ tab: TabSummary, workspace: WorkspaceSummary, selected: Bool) -> RailRow {
        let display = tab.labeled || tab.title.isEmpty ? tab.name : tab.title
        let ports = tab.server?.ports ?? []
        let icon: RailIcon = tab.isAgent ? .agent : (ports.isEmpty ? .shell : .server)
        var accessory = RailAccessory.none
        var tint: RailTone?
        var phrase: String?
        switch tab.state {
        case .needsYou:
            accessory = .word("Needs you", .needs)
            tint = .needs
            phrase = "needs you"
        case .failed where tab.launchError != nil:
            accessory = .word("Couldn't start", .failed)
            tint = .failed
            phrase = "couldn't start" + (tab.launchError.map { ", \(launchProblem($0))" } ?? "")
        case .failed:
            accessory = .word("Failed", .failed)
            tint = .failed
            if let detail = tab.stateDetail, !detail.isEmpty {
                phrase = "failed, \(detail)"
            } else {
                phrase = "failed" + (tab.lastExit.map { ", exit \($0.code)" } ?? "")
            }
        case .running where !ports.isEmpty:
            accessory = .port(":\(ports[0])" + (ports.count > 1 ? " +\(ports.count - 1)" : ""))
            phrase = "serving on port \(ports[0])"
        case .running:
            accessory = .dot(.running)
            phrase = tab.stateLabel.isEmpty ? "running" : tab.stateLabel.lowercased()
        case .done:
            accessory = .dot(.done)
            phrase = "done"
        case .starting, .stopping:
            accessory = .dot(.muted)
            phrase = tab.state.rawValue
        case .stopped:
            accessory = .ring
            tint = .muted
            phrase = "stopped"
        default:
            break
        }
        var tooltip = abbreviateHome(tab.cwd)
        if let detail = tab.stateDetail, !detail.isEmpty { tooltip += " · \(detail)" }
        return RailRow(
            key: "tab:\(tab.id)", kind: .tab(icon: icon, selected: selected), modelId: tab.id,
            workspaceId: workspace.id, text: display,
            state: tab.state, accessory: accessory, tint: tint,
            identifier: AXID.railTab(workspace: workspace.name, tab: tab.name),
            label: phrase.map { "\(display), \($0)" } ?? display, help: tab.isAgent ? "Agent tab" : "Shell tab",
            tooltip: tooltip)
    }

    /// "folder missing" for a missing folder (UX §3.8), else the daemon's message.
    private static func launchProblem(_ error: TabLaunchError) -> String {
        error.kind == "cwd_missing" ? "folder missing" : error.message.lowercased()
    }

    private static func stateWord(_ state: TabState, label: String) -> String {
        label.isEmpty ? state.rawValue.replacingOccurrences(of: "-", with: " ") : label.lowercased()
    }

    private static func tabCount(_ count: Int) -> String {
        count == 1 ? "1 tab" : "\(count) tabs"
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// `ui.snapshot.model.rail` (UX §3.8): the workspace and tab rows in display order, so drives can check what
/// the rail renders without pixels.
public enum RailSnapshot {
    public static func rows(_ store: AppStore) -> [JSONValue] {
        RailModel.rows(store).compactMap { row in
            guard let id = row.modelId else { return nil }
            let accessory = row.accessory.snapshotValue.map(JSONValue.string) ?? .null
            switch row.kind {
            case .workspace(let expanded, _):
                var members: [String: JSONValue] = [
                    "kind": .string("workspace"), "id": .string(id), "name": .string(row.text),
                    "expanded": .bool(expanded),
                    "state": .string(row.state.rawValue), "accessory": accessory,
                ]
                if let branch = row.secondaryText, !branch.isEmpty { members["branch"] = .string(branch) }
                return .object(members)
            case .tab(let icon, let selected):
                guard let tab = store.tabs[id] else { return nil }
                var members: [String: JSONValue] = [
                    "kind": .string("tab"), "id": .string(id), "workspaceId": .string(tab.workspaceId),
                    "name": .string(tab.name), "display": .string(row.text), "icon": .string(icon.rawValue),
                    "state": .string(row.state.rawValue), "accessory": accessory, "selected": .bool(selected),
                ]
                if let hint = row.hint { members["hint"] = .string(hint) }
                return .object(members)
            default:
                return nil
            }
        }
    }
}
