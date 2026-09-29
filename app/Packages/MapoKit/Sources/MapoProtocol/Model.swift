import Foundation

// Hand-written Codable types for the parts of PROTOCOL.md the app uses (DECISIONS D-15). Fields are the
// wire's camelCase names; unknown fields are ignored (PROTOCOL §2, additive evolution). Summaries decode
// their non-identity fields leniently so an older or newer daemon still renders.

/// Method names the app calls (PROTOCOL §6).
public enum Method {
    public static let hello = "hello"
    public static let ping = "ping"
    public static let stateSnapshot = "state.snapshot"
    public static let eventsSubscribe = "events.subscribe"
    public static let workspaceCreate = "workspace.create"
    public static let workspaceActivate = "workspace.activate"
    public static let tabCreate = "tab.create"
    public static let tabFocus = "tab.focus"
    /// The notification that carries an `Event`.
    public static let event = "event"
}

// MARK: - Handshake (PROTOCOL §2, §3)

public struct Credential: Codable, Hashable, Sendable, CustomStringConvertible {
    public var kind: String
    public var token: String

    public init(kind: String, token: String) {
        self.kind = kind
        self.token = token
    }

    /// The operator credential from `app.token`.
    public static func app(token: String) -> Credential { Credential(kind: "app", token: token) }

    /// Never prints the token.
    public var description: String { "Credential(kind: \(kind), token: ***)" }
}

public struct HelloParams: Codable, Hashable, Sendable {
    public var `protocol`: Int
    public var role: String
    public var client: String
    public var credential: Credential

    public init(protocol: Int = MapoProtocolVersion.current, role: String, client: String, credential: Credential) {
        self.protocol = `protocol`
        self.role = role
        self.client = client
        self.credential = credential
    }
}

public struct Caller: Codable, Hashable, Sendable {
    public var kind: String
    public var tabId: String?
    public var workspaceId: String?
}

public struct HelloResult: Codable, Hashable, Sendable {
    public var `protocol`: Int
    public var daemon: String
    public var bootId: String
    public var instance: String
    public var features: [String]?
    public var caller: Caller?
}

public struct PingResult: Codable, Hashable, Sendable {
    public var bootId: String
    public var uptimeMs: Int
}

// MARK: - Shared types (PROTOCOL §7)

/// A tab or workspace state, kebab-case on the wire. Unknown states survive as their raw string.
public struct TabState: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let needsYou = TabState(rawValue: "needs-you")
    public static let failed = TabState(rawValue: "failed")
    public static let running = TabState(rawValue: "running")
    public static let done = TabState(rawValue: "done")
    public static let starting = TabState(rawValue: "starting")
    public static let stopping = TabState(rawValue: "stopping")
    public static let idle = TabState(rawValue: "idle")
    public static let stopped = TabState(rawValue: "stopped")
}

public struct WorkspaceSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var order: Int
    public var agentCommand: String?
    public var activeTabId: String?
    public var state: TabState
    public var stateLabel: String
    public var summary: String
    public var attentionCount: Int
    public var tabCount: Int
    public var branch: String?

    public init(
        id: String, name: String, order: Int = 0, agentCommand: String? = nil, activeTabId: String? = nil,
        state: TabState = .idle, stateLabel: String = "Idle", summary: String = "", attentionCount: Int = 0,
        tabCount: Int = 0, branch: String? = nil
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.agentCommand = agentCommand
        self.activeTabId = activeTabId
        self.state = state
        self.stateLabel = stateLabel
        self.summary = summary
        self.attentionCount = attentionCount
        self.tabCount = tabCount
        self.branch = branch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        agentCommand = try c.decodeIfPresent(String.self, forKey: .agentCommand)
        activeTabId = try c.decodeIfPresent(String.self, forKey: .activeTabId)
        state = try c.decodeIfPresent(TabState.self, forKey: .state) ?? .idle
        stateLabel = try c.decodeIfPresent(String.self, forKey: .stateLabel) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        attentionCount = try c.decodeIfPresent(Int.self, forKey: .attentionCount) ?? 0
        tabCount = try c.decodeIfPresent(Int.self, forKey: .tabCount) ?? 0
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
    }
}

public struct TabLaunch: Codable, Hashable, Sendable {
    public var cwd: String
    public var command: String?
    public var agentCommand: String?
}

public struct TabAgentInfo: Codable, Hashable, Sendable {
    public var hooksConnected: Bool
    public var sessionId: String?
}

public struct TabServerInfo: Codable, Hashable, Sendable {
    public var ports: [Int]
}

public struct TabExit: Codable, Hashable, Sendable {
    public var code: Int
    public var durationMs: Int?
}

public struct TabLaunchError: Codable, Hashable, Sendable {
    public var kind: String
    public var message: String
    public var path: String?
}

public struct TabSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var workspaceId: String
    public var name: String
    public var labeled: Bool
    public var title: String
    /// `shell` or `agent`.
    public var kind: String
    public var order: Int
    public var cwd: String
    public var launch: TabLaunch?
    public var state: TabState
    public var stateLabel: String
    public var stateDetail: String?
    public var statusSource: String?
    public var program: String?
    public var visible: Bool
    public var paneId: String?
    public var agent: TabAgentInfo?
    public var server: TabServerInfo?
    public var lastExit: TabExit?
    public var launchError: TabLaunchError?

    public init(
        id: String, workspaceId: String, name: String, labeled: Bool = false, title: String = "",
        kind: String = "shell", order: Int = 0, cwd: String = "", state: TabState = .idle, stateLabel: String = ""
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.labeled = labeled
        self.title = title
        self.kind = kind
        self.order = order
        self.cwd = cwd
        self.state = state
        self.stateLabel = stateLabel
        self.visible = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        name = try c.decode(String.self, forKey: .name)
        labeled = try c.decodeIfPresent(Bool.self, forKey: .labeled) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "shell"
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        launch = try c.decodeIfPresent(TabLaunch.self, forKey: .launch)
        state = try c.decodeIfPresent(TabState.self, forKey: .state) ?? .idle
        stateLabel = try c.decodeIfPresent(String.self, forKey: .stateLabel) ?? ""
        stateDetail = try c.decodeIfPresent(String.self, forKey: .stateDetail)
        statusSource = try c.decodeIfPresent(String.self, forKey: .statusSource)
        program = try c.decodeIfPresent(String.self, forKey: .program)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? false
        paneId = try c.decodeIfPresent(String.self, forKey: .paneId)
        agent = try c.decodeIfPresent(TabAgentInfo.self, forKey: .agent)
        server = try c.decodeIfPresent(TabServerInfo.self, forKey: .server)
        lastExit = try c.decodeIfPresent(TabExit.self, forKey: .lastExit)
        launchError = try c.decodeIfPresent(TabLaunchError.self, forKey: .launchError)
    }

    public var isAgent: Bool { kind == "agent" || agent != nil }
}

public struct DiffRef: Codable, Hashable, Sendable {
    public var root: String
    public var path: String
}

/// What a pane shows: `{tab:id} | {file:path} | {diff:{root,path}} | {empty:true}`.
public enum PaneContent: Codable, Hashable, Sendable {
    case tab(String)
    case file(String)
    case diff(DiffRef)
    case empty

    private enum CodingKeys: String, CodingKey { case tab, file, diff, empty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let tab = try c.decodeIfPresent(String.self, forKey: .tab) {
            self = .tab(tab)
        } else if let file = try c.decodeIfPresent(String.self, forKey: .file) {
            self = .file(file)
        } else if let diff = try c.decodeIfPresent(DiffRef.self, forKey: .diff) {
            self = .diff(diff)
        } else {
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let id): try c.encode(id, forKey: .tab)
        case .file(let path): try c.encode(path, forKey: .file)
        case .diff(let ref): try c.encode(ref, forKey: .diff)
        case .empty: try c.encode(true, forKey: .empty)
        }
    }

    public var tabId: String? {
        if case .tab(let id) = self { return id }
        return nil
    }
}

/// A node of the layout tree: a split or a pane.
public indirect enum LayoutNode: Codable, Hashable, Sendable {
    case split(id: String, axis: String, ratios: [Double], children: [LayoutNode])
    case pane(id: String, content: PaneContent, recentFiles: [String])

    private enum CodingKeys: String, CodingKey { case kind, id, axis, ratios, children, content, recentFiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        if try c.decode(String.self, forKey: .kind) == "split" {
            self = .split(
                id: id, axis: try c.decodeIfPresent(String.self, forKey: .axis) ?? "row",
                ratios: try c.decodeIfPresent([Double].self, forKey: .ratios) ?? [],
                children: try c.decodeIfPresent([LayoutNode].self, forKey: .children) ?? [])
        } else {
            self = .pane(
                id: id, content: try c.decodeIfPresent(PaneContent.self, forKey: .content) ?? .empty,
                recentFiles: try c.decodeIfPresent([String].self, forKey: .recentFiles) ?? [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let id, let axis, let ratios, let children):
            try c.encode("split", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(axis, forKey: .axis)
            try c.encode(ratios, forKey: .ratios)
            try c.encode(children, forKey: .children)
        case .pane(let id, let content, let recentFiles):
            try c.encode("pane", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(content, forKey: .content)
            try c.encode(recentFiles, forKey: .recentFiles)
        }
    }

    public var id: String {
        switch self {
        case .split(let id, _, _, _), .pane(let id, _, _): id
        }
    }

    /// The pane with `id` in this subtree.
    public func pane(id target: String) -> (id: String, content: PaneContent)? {
        switch self {
        case .pane(let id, let content, _):
            return id == target ? (id, content) : nil
        case .split(_, _, _, let children):
            for child in children {
                if let found = child.pane(id: target) { return found }
            }
            return nil
        }
    }

    /// The first pane in tree order.
    public var firstPane: (id: String, content: PaneContent)? {
        switch self {
        case .pane(let id, let content, _): (id, content)
        case .split(_, _, _, let children): children.lazy.compactMap(\.firstPane).first
        }
    }
}

public struct Layout: Codable, Hashable, Sendable {
    public var workspaceId: String
    public var focusedPaneId: String?
    public var root: LayoutNode

    /// The focused pane, else the first one.
    public var focusedPane: (id: String, content: PaneContent)? {
        if let focusedPaneId, let pane = root.pane(id: focusedPaneId) { return pane }
        return root.firstPane
    }
}

// MARK: - State and events (PROTOCOL §6.1, §7)

public struct StateSnapshot: Codable, Hashable, Sendable {
    public var seq: Int
    public var bootId: String
    public var activeWorkspaceId: String?
    public var workspaces: [WorkspaceSummary]
    public var tabs: [TabSummary]
    public var layouts: [String: Layout]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        bootId = try c.decode(String.self, forKey: .bootId)
        activeWorkspaceId = try c.decodeIfPresent(String.self, forKey: .activeWorkspaceId)
        workspaces = try c.decodeIfPresent([WorkspaceSummary].self, forKey: .workspaces) ?? []
        tabs = try c.decodeIfPresent([TabSummary].self, forKey: .tabs) ?? []
        layouts = try c.decodeIfPresent([String: Layout].self, forKey: .layouts) ?? [:]
    }
}

public struct EventsSubscribeParams: Codable, Hashable, Sendable {
    public var after: Int?
    public var types: [String]?

    public init(after: Int? = nil, types: [String]? = nil) {
        self.after = after
        self.types = types
    }
}

public struct EventsSubscribeResult: Codable, Hashable, Sendable {
    public var seq: Int
}

public struct IdRef: Codable, Hashable, Sendable {
    public var id: String
}

public struct TabClosed: Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
}

public struct TabStateChange: Codable, Hashable, Sendable {
    public var tabId: String
    public var workspaceId: String
    public var state: TabState
    public var previous: TabState?
    public var stateLabel: String?
    public var source: String?
}

public struct AttentionChanged: Codable, Hashable, Sendable {
    public var count: Int
    public var tabIds: [String]
}

public struct DaemonStopping: Codable, Hashable, Sendable {
    public var reason: String?
}

/// The typed `data` of the events the app applies. Everything else is `.other`.
public enum EventPayload: Hashable, Sendable {
    case workspaceCreated(WorkspaceSummary)
    case workspaceUpdated(WorkspaceSummary)
    case workspaceMoved(WorkspaceSummary)
    case workspaceDeleted(IdRef)
    case workspaceActivated(IdRef)
    case tabCreated(TabSummary)
    case tabUpdated(TabSummary)
    case tabMoved(TabSummary)
    case tabClosed(TabClosed)
    case tabState(TabStateChange)
    case layoutUpdated(Layout)
    case attentionChanged(AttentionChanged)
    case appConnected
    case appDisconnected
    case daemonStopping(DaemonStopping)
    case other
}

/// `{seq, bootId, at, type, data}`, the params of an `event` notification.
public struct Event: Decodable, Hashable, Sendable {
    public var seq: Int
    public var bootId: String
    /// The timestamp as the daemon sent it.
    public var at: JSONValue?
    public var type: String
    public var payload: EventPayload

    private enum CodingKeys: String, CodingKey { case seq, bootId, at, type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        bootId = try c.decode(String.self, forKey: .bootId)
        at = try c.decodeIfPresent(JSONValue.self, forKey: .at)
        type = try c.decode(String.self, forKey: .type)
        func data<T: Decodable>(_: T.Type) throws -> T { try c.decode(T.self, forKey: .data) }
        switch type {
        case "workspace.created": payload = .workspaceCreated(try data(WorkspaceSummary.self))
        case "workspace.updated": payload = .workspaceUpdated(try data(WorkspaceSummary.self))
        case "workspace.moved": payload = .workspaceMoved(try data(WorkspaceSummary.self))
        case "workspace.deleted": payload = .workspaceDeleted(try data(IdRef.self))
        case "workspace.activated": payload = .workspaceActivated(try data(IdRef.self))
        case "tab.created": payload = .tabCreated(try data(TabSummary.self))
        case "tab.updated": payload = .tabUpdated(try data(TabSummary.self))
        case "tab.moved": payload = .tabMoved(try data(TabSummary.self))
        case "tab.closed": payload = .tabClosed(try data(TabClosed.self))
        case "tab.state": payload = .tabState(try data(TabStateChange.self))
        case "layout.updated": payload = .layoutUpdated(try data(Layout.self))
        case "attention.changed": payload = .attentionChanged(try data(AttentionChanged.self))
        case "app.connected": payload = .appConnected
        case "app.disconnected": payload = .appDisconnected
        case "daemon.stopping": payload = .daemonStopping(try data(DaemonStopping.self))
        default: payload = .other
        }
    }
}

// MARK: - Method params (PROTOCOL §6.2, §6.3)

public struct WorkspaceCreateParams: Codable, Hashable, Sendable {
    public var name: String?
    public init(name: String? = nil) { self.name = name }
}

public struct WorkspaceSelector: Codable, Hashable, Sendable {
    public var workspace: String
    public init(workspace: String) { self.workspace = workspace }
}

public struct TabCreateParams: Codable, Hashable, Sendable {
    public var workspace: String?
    public var name: String?
    public var kind: String?
    public var cwd: String?
    public var command: String?
    public var agentCommand: String?
    public var placement: String?
    public var focus: Bool?

    public init(
        workspace: String? = nil, name: String? = nil, kind: String? = nil, cwd: String? = nil,
        command: String? = nil, agentCommand: String? = nil, placement: String? = nil, focus: Bool? = nil
    ) {
        self.workspace = workspace
        self.name = name
        self.kind = kind
        self.cwd = cwd
        self.command = command
        self.agentCommand = agentCommand
        self.placement = placement
        self.focus = focus
    }
}

public struct TabSelector: Codable, Hashable, Sendable {
    public var tab: String
    public var workspace: String?
    public init(tab: String, workspace: String? = nil) {
        self.tab = tab
        self.workspace = workspace
    }
}
