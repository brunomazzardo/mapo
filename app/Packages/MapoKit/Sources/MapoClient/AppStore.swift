import Foundation
import MapoProtocol
import Observation

/// The app's mirror of daemon state: filled by `state.snapshot`, then kept current by events applied in
/// `seq` order (PLAN T0.7 step 6). Views watch it with `withObservationTracking`.
@Observable
public final class AppStore {
    /// The control connection, which drives `app.banner` (UX §4.3).
    public enum Connection: Equatable, Sendable {
        /// The first attempt is still under way; no banner yet.
        case connecting
        case connected(bootId: String)
        /// Unreachable since `since`: "Reconnecting to mapod…", then after 10 s "Can't reach mapod."
        case reconnecting(since: Date)
        /// The daemon speaks another protocol version (PROTOCOL §2).
        case protocolMismatch(daemon: Int, app: Int)
    }

    public let instance: String
    public var connection: Connection = .connecting
    /// True while Restart mapod runs.
    public var isRestartingDaemon = false

    public private(set) var hasSnapshot = false
    public private(set) var bootId: String?
    public private(set) var seq = 0
    public private(set) var activeWorkspaceId: String?
    /// In rail order.
    public private(set) var workspaces: [WorkspaceSummary] = []
    public private(set) var tabs: [String: TabSummary] = [:]
    public private(set) var layouts: [String: Layout] = [:]

    public init(instance: String) {
        self.instance = instance
    }

    public var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    public var activeWorkspace: WorkspaceSummary? {
        guard let activeWorkspaceId else { return nil }
        return workspaces.first { $0.id == activeWorkspaceId }
    }

    public func workspace(id: String) -> WorkspaceSummary? {
        workspaces.first { $0.id == id }
    }

    /// The workspace's tabs in rail order.
    public func tabs(inWorkspace workspaceId: String) -> [TabSummary] {
        tabs.values.filter { $0.workspaceId == workspaceId }.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// The pane the workspace shows: the layout's focused pane, else a pane made from `activeTabId`.
    public func focusedPane(inWorkspace workspaceId: String) -> (id: String?, content: PaneContent) {
        if let pane = layouts[workspaceId]?.focusedPane { return (pane.id, pane.content) }
        if let tabId = workspace(id: workspaceId)?.activeTabId, tabs[tabId] != nil {
            return (tabs[tabId]?.paneId, .tab(tabId))
        }
        return (nil, .empty)
    }

    /// The tab in the focused pane of the workspace, which the rail selects (UX §3.2).
    public func focusedTabId(inWorkspace workspaceId: String) -> String? {
        focusedPane(inWorkspace: workspaceId).content.tabId ?? workspace(id: workspaceId)?.activeTabId
    }

    // MARK: Sync

    /// Replaces everything with a snapshot.
    public func load(_ snapshot: StateSnapshot) {
        bootId = snapshot.bootId
        seq = snapshot.seq
        activeWorkspaceId = snapshot.activeWorkspaceId
        workspaces = snapshot.workspaces.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        tabs = Dictionary(snapshot.tabs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        layouts = snapshot.layouts
        hasSnapshot = true
    }

    /// Applies one event. Events from another boot or at or below `seq` are ignored.
    /// Returns false when the event was skipped.
    @discardableResult
    public func apply(_ event: Event) -> Bool {
        guard event.bootId == bootId, event.seq > seq else { return false }
        seq = event.seq
        switch event.payload {
        case .workspaceCreated(let workspace), .workspaceUpdated(let workspace), .workspaceMoved(let workspace):
            upsert(workspace)
        case .workspaceDeleted(let ref):
            workspaces.removeAll { $0.id == ref.id }
            tabs = tabs.filter { $0.value.workspaceId != ref.id }
            layouts.removeValue(forKey: ref.id)
            if activeWorkspaceId == ref.id { activeWorkspaceId = nil }
        case .workspaceActivated(let ref):
            activeWorkspaceId = ref.id
        case .tabCreated(let tab), .tabUpdated(let tab), .tabMoved(let tab):
            tabs[tab.id] = tab
        case .tabClosed(let closed):
            tabs.removeValue(forKey: closed.id)
        case .tabState(let change):
            if var tab = tabs[change.tabId] {
                tab.state = change.state
                if let label = change.stateLabel { tab.stateLabel = label }
                tabs[change.tabId] = tab
            }
        case .layoutUpdated(let layout):
            layouts[layout.workspaceId] = layout
        case .attentionChanged, .appConnected, .appDisconnected, .daemonStopping, .fsChanged, .gitChanged, .other:
            break
        }
        return true
    }

    private func upsert(_ workspace: WorkspaceSummary) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            if workspaces[index] == workspace { return }
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
        workspaces.sort { ($0.order, $0.name) < ($1.order, $1.name) }
    }
}
