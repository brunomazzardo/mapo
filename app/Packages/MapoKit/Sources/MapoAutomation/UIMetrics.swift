import AppKit
import Darwin
import MapoClient
import MapoProtocol
import MapoUI
import Observation

/// The basic `ui.metrics` of PLAN T0.9 step 6: launch time and navigation spans. `frames` stays empty
/// until M5, and the daemon adds `attach`.
///
/// A span runs from its trigger (the input event's timestamp, or now for automation and menu actions
/// without one) to the first frame showing the new state. The first frame is approximated as the next
/// main-runloop turn after the window displayed the store's new state.
public final class UIMetrics {
    /// Navigation names of ENGINEERING §4.3 that M0 records.
    public enum Navigation: String, Sendable {
        case appReattach = "app.reattach"
        case workspaceSwitch = "workspace.switch"
        case tabFocus = "tab.focus"
        case tabCreate = "tab.create"
        case paneSplit = "pane.split"
    }

    private struct Span {
        let name: Navigation
        let start: TimeInterval
        let until: @MainActor () -> Bool
    }

    private let store: AppStore
    private let window: () -> NSWindow?
    private var launchMs: Double?
    private var navigation: [(name: String, ms: Double)] = []
    private var pending: [Int: Span] = [:]
    private var nextSpan = 0
    private var wasConnected = false

    private static let keep = 200
    /// Spans that never see their state give up after this long rather than report a bogus time.
    private static let spanTimeout: TimeInterval = 15

    public init(store: AppStore, window: @escaping () -> NSWindow?) {
        self.store = store
        self.window = window
        watchLaunch()
        watchConnection()
    }

    // MARK: Recording

    /// Starts `name` at the triggering input event, or now, and ends it once `until` holds and a frame
    /// shows it. `until` reads the store, so it re-checks on every change it depends on.
    public func begin(_ name: Navigation, until: @escaping @MainActor () -> Bool) {
        start(Span(name: name, start: Self.triggerTime(), until: until))
    }

    /// `tab.create`: until the active workspace's focused tab is one that didn't exist at the start.
    public func beginTabCreate() {
        let known = Set(store.tabs.keys)
        let store = store
        begin(.tabCreate) {
            guard let workspaceId = store.activeWorkspaceId,
                let tabId = store.focusedTabId(inWorkspace: workspaceId)
            else { return false }
            return !known.contains(tabId)
        }
    }

    /// `workspace.switch` to a new workspace (⇧⌘N): until a workspace that didn't exist is active.
    public func beginWorkspaceCreate() {
        let known = Set(store.workspaces.map(\.id))
        let store = store
        begin(.workspaceSwitch) {
            guard let id = store.activeWorkspaceId else { return false }
            return !known.contains(id)
        }
    }

    public func beginWorkspaceSwitch(to workspaceId: String) {
        let store = store
        begin(.workspaceSwitch) { store.activeWorkspaceId == workspaceId }
    }

    /// `pane.split` (⌘D, ⇧⌘D): until the active workspace focuses a new pane whose tab the store knows.
    public func beginPaneSplit() {
        let store = store
        let workspaceId = store.activeWorkspaceId
        let before = workspaceId.flatMap { store.layouts[$0]?.focusedPaneId }
        begin(.paneSplit) {
            guard let workspaceId, let pane = store.layouts[workspaceId]?.focusedPane, pane.id != before,
                let tabId = pane.content.tabId
            else { return false }
            return store.tabs[tabId] != nil
        }
    }

    public func beginTabFocus(_ tabId: String) {
        let store = store
        begin(.tabFocus) {
            guard let workspaceId = store.activeWorkspaceId else { return false }
            return store.focusedTabId(inWorkspace: workspaceId) == tabId
        }
    }

    // MARK: ui.metrics

    public func json(reset: Bool) -> JSONValue {
        let result: JSONValue = .object([
            "launch": .object(["processStartToFirstFrameMs": launchMs.map(JSONValue.number) ?? .null]),
            "navigation": .array(
                navigation.map { .object(["name": .string($0.name), "ms": .number($0.ms)]) }),
            "frames": .object(["p50Ms": .null, "p95Ms": .null, "dropped": .number(0)]),
        ])
        if reset { navigation.removeAll() }
        return result
    }

    // MARK: Internals

    /// The launch span: process start to the first frame after the first snapshot.
    private func watchLaunch() {
        let store = store
        watch({ store.hasSnapshot }) { [weak self] in
            self?.afterNextFrame { [weak self] in
                guard let self, let start = Self.processStartTime() else { return }
                let ms = Self.milliseconds(Date().timeIntervalSince(start))
                launchMs = ms
                MapoLog.shared.info("metrics launch.processStartToFirstFrameMs=\(ms)")
            }
        }
    }

    /// `app.reattach`: from losing the daemon to the reconnected, re-synced UI.
    private func watchConnection() {
        observeContinuously(self) { metrics in
            let connected = metrics.store.isConnected
            defer { metrics.wasConnected = connected }
            guard metrics.wasConnected, !connected else { return }
            let store = metrics.store
            let span = Span(
                name: .appReattach, start: ProcessInfo.processInfo.systemUptime,
                until: { store.isConnected && store.hasSnapshot })
            // Start on the next turn, outside this observation's tracking scope.
            DispatchQueue.main.async { metrics.start(span) }
        }
    }

    private func start(_ span: Span) {
        let key = nextSpan
        nextSpan += 1
        pending[key] = span
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spanTimeout) { [weak self] in
            guard self?.pending.removeValue(forKey: key) != nil else { return }
            MapoLog.shared.debug("metrics \(span.name.rawValue) gave up")
        }
        check(key)
    }

    private func check(_ key: Int) {
        guard let span = pending[key] else { return }
        let satisfied = withObservationTracking {
            span.until()
        } onChange: { [weak self] in
            Task { @MainActor in self?.check(key) }
        }
        guard satisfied else { return }
        pending[key] = nil
        afterNextFrame { [weak self] in
            guard let self else { return }
            let ms = Self.milliseconds(ProcessInfo.processInfo.systemUptime - span.start)
            navigation.append((span.name.rawValue, ms))
            if navigation.count > Self.keep { navigation.removeFirst(navigation.count - Self.keep) }
            MapoLog.shared.info("metrics \(span.name.rawValue) ms=\(ms)")
        }
    }

    /// Runs `body` once `condition` holds, now or after a later store change.
    private func watch(_ condition: @escaping @MainActor () -> Bool, then body: @escaping @MainActor () -> Void) {
        let satisfied = withObservationTracking {
            condition()
        } onChange: { [weak self] in
            Task { @MainActor in self?.watch(condition, then: body) }
        }
        if satisfied { body() }
    }

    /// Lets the views re-render from the store (their observers run on the next turns), displays the window,
    /// then runs `body` on the turn after that display.
    private func afterNextFrame(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.window()?.displayIfNeeded()
            DispatchQueue.main.async { body() }
        }
    }

    /// The current input event's timestamp when a person or `ui.*` triggered the action; otherwise now.
    private static func triggerTime() -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        guard let event = NSApp.currentEvent else { return now }
        switch event.type {
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            // A stale event belongs to an earlier action.
            return now - event.timestamp < 1 ? event.timestamp : now
        default:
            return now
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Double {
        (seconds * 10_000).rounded() / 10
    }

    /// The process start time from `sysctl(KERN_PROC_PID)`.
    private static func processStartTime() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
