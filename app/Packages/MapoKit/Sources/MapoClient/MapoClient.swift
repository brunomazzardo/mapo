import Foundation
import MapoProtocol

/// Keeps the app connected to its instance's daemon and the `AppStore` in sync (PLAN T0.7 steps 5–6).
///
/// Each attempt reads `app.token` afresh (it rotates every daemon boot), connects, sends `hello` as the app,
/// checks the instance, then takes `state.snapshot` (on a new `bootId`) and `events.subscribe {after: seq}`.
/// When the socket is missing or refuses, it spawns the daemon unless spawning is off; otherwise it
/// retries with backoff while `app.banner` explains (UX §4.3).
public final class MapoClient {
    public struct Configuration: Sendable {
        public var instance: InstanceInfo
        public var helper: MapoHelper
        /// False with `--no-spawn-daemon`: wait and reconnect instead.
        public var spawnDaemon: Bool
        /// `client` in `hello`, such as "Mapo/0.1.0".
        public var clientName: String

        public init(instance: InstanceInfo, helper: MapoHelper, spawnDaemon: Bool, clientName: String) {
            self.instance = instance
            self.helper = helper
            self.spawnDaemon = spawnDaemon
            self.clientName = clientName
        }
    }

    public enum ClientError: Error, CustomStringConvertible {
        case notConnected
        case tokenUnreadable(String)
        case wrongInstance(expected: String, actual: String)

        public var description: String {
            switch self {
            case .notConnected: "not connected to mapod"
            case .tokenUnreadable(let path): "can't read the app token at \(path)"
            case .wrongInstance(let expected, let actual):
                "the socket is served by instance \(actual), not \(expected)"
            }
        }
    }

    public let store: AppStore
    public let configuration: Configuration
    /// Serves daemon-originated requests (`ui.*`, T0.9) on every connection.
    public var requestHandler: MapoConnection.RequestHandler? {
        didSet { connection?.setRequestHandler(requestHandler) }
    }

    private let launcher: DaemonLauncher
    private let log = MapoLog.shared
    private var connection: MapoConnection?
    private var loop: Task<Void, Never>?
    private var backoff: Task<Void, Never>?
    private var lastSpawn: Date?
    private var forceSnapshot = false

    private static let backoffSteps: [Double] = [0.25, 0.5, 1, 2, 3]
    private static let spawnInterval: TimeInterval = 10

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.store = AppStore(instance: configuration.instance.name)
        self.launcher = DaemonLauncher(helper: configuration.helper, instance: configuration.instance.name)
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        backoff?.cancel()
        connection?.cancel()
        connection = nil
    }

    /// Calls a daemon method on the current connection.
    public func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, _ params: Params, as type: Result.Type = Result.self
    ) async throws -> Result {
        guard let connection, store.isConnected else { throw ClientError.notConnected }
        return try await connection.request(method, params, as: type)
    }

    /// Restart mapod (`app.banner.action`): stop whatever serves the instance, start a fresh daemon and
    /// reconnect now. Runs even with `--no-spawn-daemon`, because the user asked for it.
    public func restartDaemon() async {
        guard !store.isRestartingDaemon else { return }
        store.isRestartingDaemon = true
        defer { store.isRestartingDaemon = false }
        log.info("restart mapod requested")
        do {
            try await launcher.stop()
        } catch {
            log.info("instance stop before restart: \(error)")
        }
        do {
            let pid = try await launcher.launch()
            lastSpawn = Date()
            log.info("daemon started pid=\(pid.map(String.init) ?? "?")")
        } catch {
            log.error("daemon start failed: \(error)")
        }
        retryNow()
    }

    /// Ends the current backoff wait so the next attempt starts now.
    public func retryNow() {
        backoff?.cancel()
    }

    // MARK: Connect loop

    private enum Attempt {
        /// Connected, synced, then lost the connection.
        case disconnected
        /// Never got to connected.
        case failed(Error)
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            switch await attempt() {
            case .disconnected:
                failures = 0
                markUnreachable()
            case .failed(let error):
                // Log the first failure of a streak at warn; repeats of a missing socket only at debug.
                if case ConnectionError.posix = error, failures > 0 {
                    log.debug("connect failed: \(error)")
                } else {
                    log.warn("connect failed: \(error)")
                }
                if case .protocolMismatch = store.connection {} else { markUnreachable() }
                let delay = Self.backoffSteps[min(failures, Self.backoffSteps.count - 1)]
                failures += 1
                let wait = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
                backoff = wait
                await wait.value
            }
        }
    }

    private func markUnreachable() {
        if case .reconnecting = store.connection { return }
        store.connection = .reconnecting(since: Date())
    }

    private func attempt() async -> Attempt {
        let connection: MapoConnection
        let hello: HelloResult
        do {
            (connection, hello) = try await connectSpawningIfNeeded()
        } catch {
            return .failed(error)
        }
        self.connection = connection
        do {
            try await sync(connection, bootId: hello.bootId)
        } catch {
            connection.cancel()
            self.connection = nil
            return .failed(error)
        }
        store.connection = .connected(bootId: hello.bootId)
        log.info("connected bootId=\(hello.bootId) instance=\(hello.instance) daemon=\(hello.daemon)")
        for await notification in connection.notifications {
            switch notification {
            case .event(let event):
                store.apply(event)
                if case .daemonStopping(let stopping) = event.payload {
                    log.info("daemon stopping: \(stopping.reason ?? "no reason")")
                }
            case .undecodable(let method, let reason):
                log.error("undecodable \(method): \(reason); resyncing")
                forceSnapshot = true
                connection.cancel()
            case .other:
                break
            }
        }
        self.connection = nil
        log.info("disconnected from bootId=\(hello.bootId)")
        return .disconnected
    }

    /// Connects and says hello. When no daemon serves the socket, spawns one (at most every 10 s) and tries
    /// once more.
    private func connectSpawningIfNeeded() async throws -> (MapoConnection, HelloResult) {
        do {
            return try await connectAndHello()
        } catch let error where Self.isDaemonAbsent(error) && configuration.spawnDaemon {
            if let lastSpawn, Date().timeIntervalSince(lastSpawn) < Self.spawnInterval { throw error }
            lastSpawn = Date()
            log.info("no daemon at \(configuration.instance.socket) (\(error)); starting one")
            let pid = try await launcher.launch()
            log.info("daemon started pid=\(pid.map(String.init) ?? "?")")
            return try await connectAndHello()
        }
    }

    private static func isDaemonAbsent(_ error: Error) -> Bool {
        if let error = error as? ConnectionError { return error.isDaemonAbsent }
        if case ClientError.tokenUnreadable = error { return true }
        return false
    }

    private func connectAndHello() async throws -> (MapoConnection, HelloResult) {
        let tokenPath = configuration.instance.token
        guard let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) else {
            // No token means no daemon has booted this instance yet, unless something odd holds the socket.
            throw FileManager.default.fileExists(atPath: configuration.instance.socket)
                ? ClientError.tokenUnreadable(tokenPath) : ConnectionError.posix(.ENOENT)
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = MapoConnection(socketPath: configuration.instance.socket)
        connection.setRequestHandler(requestHandler)
        do {
            try await connection.start()
            let params = HelloParams(role: "app", client: configuration.clientName, credential: .app(token: token))
            let hello = try await connection.request(Method.hello, params, as: HelloResult.self, timeout: .seconds(10))
            guard hello.instance == configuration.instance.name else {
                throw ClientError.wrongInstance(expected: configuration.instance.name, actual: hello.instance)
            }
            return (connection, hello)
        } catch let error as RPCError {
            connection.cancel()
            if error.kind == .unavailable, let daemonProtocol = error.data?.daemonProtocol {
                store.connection = .protocolMismatch(daemon: daemonProtocol, app: MapoProtocolVersion.current)
            }
            throw error
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// Snapshot (on a new boot or after a resync request) and subscribe from the store's `seq`.
    private func sync(_ connection: MapoConnection, bootId: String) async throws {
        if bootId != store.bootId || forceSnapshot || !store.hasSnapshot {
            try await loadSnapshot(connection)
        }
        do {
            _ = try await subscribe(connection)
        } catch let error as RPCError where error.kind == .conflict {
            log.info("event cursor expired at seq=\(store.seq); taking a fresh snapshot")
            try await loadSnapshot(connection)
            _ = try await subscribe(connection)
        }
    }

    private func loadSnapshot(_ connection: MapoConnection) async throws {
        let snapshot = try await connection.request(Method.stateSnapshot, EmptyObject(), as: StateSnapshot.self)
        store.load(snapshot)
        forceSnapshot = false
        log.info(
            "snapshot seq=\(snapshot.seq) workspaces=\(snapshot.workspaces.count) tabs=\(snapshot.tabs.count)")
    }

    private func subscribe(_ connection: MapoConnection) async throws -> EventsSubscribeResult {
        try await connection.request(
            Method.eventsSubscribe, EventsSubscribeParams(after: store.seq), as: EventsSubscribeResult.self)
    }
}

// MARK: - Commands the menus call (UX §8)

extension MapoClient {
    /// New Workspace (⇧⌘N): `workspace.create`, then one shell tab in the home folder, focused (PA-23).
    @discardableResult
    public func newWorkspace() async throws -> WorkspaceSummary {
        let workspace = try await call(Method.workspaceCreate, WorkspaceCreateParams(), as: WorkspaceSummary.self)
        _ = try await call(
            Method.workspaceActivate, WorkspaceSelector(workspace: workspace.id), as: WorkspaceSummary.self)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        _ = try await call(
            Method.tabCreate,
            TabCreateParams(workspace: workspace.id, kind: "shell", cwd: home, placement: "focused", focus: true),
            as: TabSummary.self)
        return workspace
    }

    /// New Shell Tab (⌘T): the daemon picks the focused tab's folder, else home. With no workspace it makes
    /// "Workspace N" first (PA-23).
    public func newShellTab() async throws {
        if store.workspaces.isEmpty {
            try await newWorkspace()
            return
        }
        _ = try await call(
            Method.tabCreate, TabCreateParams(kind: "shell", placement: "focused", focus: true), as: TabSummary.self)
    }

    public func activateWorkspace(id: String) async throws {
        _ = try await call(Method.workspaceActivate, WorkspaceSelector(workspace: id), as: WorkspaceSummary.self)
    }

    public func focusTab(id: String) async throws {
        _ = try await call(Method.tabFocus, TabSelector(tab: id), as: TabSummary.self)
    }
}
