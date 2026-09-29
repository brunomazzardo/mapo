import AppKit

/// Terminal bodies by tab id. A body lives until its tab closes, so re-layout, pane moves and zoom
/// re-host the same view instead of building a new surface (PLAN T0.8).
public final class SurfaceRegistry {
    /// The launch settings, with the font size View › Bigger and Smaller set (UX §8).
    public private(set) var settings: TerminalSettings
    private let launch: (_ tabId: String) -> TerminalLaunch
    private let identifiers: TerminalIdentifiers
    private var hosts: [String: TerminalHostView] = [:]
    private var detachTasks: [String: Task<Void, Never>] = [:]

    /// How long a hidden surface lives before it is freed (ARCHITECTURE §4.3).
    public var detachDelay: Duration = .seconds(30)

    /// - Parameters:
    ///   - identifiers: the terminal identifiers for a tab name (`AXID` in MapoUI).
    ///   - launch: the process for a tab's surface, normally `TerminalLaunch.attach`.
    public init(
        settings: TerminalSettings, identifiers: @escaping TerminalIdentifiers,
        launch: @escaping (_ tabId: String) -> TerminalLaunch
    ) {
        self.settings = settings
        self.identifiers = identifiers
        self.launch = launch
    }

    /// The registry the app uses: every surface runs `<APP>/Contents/Helpers/mapo attach`.
    public convenience init(
        settings: TerminalSettings, instance: String, identifiers: @escaping TerminalIdentifiers,
        bundle: Bundle = .main
    ) {
        let helper = TerminalLaunch.helperURL(in: bundle)
        self.init(settings: settings, identifiers: identifiers) {
            TerminalLaunch.attach(helper: helper, tabId: $0, instance: instance)
        }
    }

    public var tabIds: [String] { Array(hosts.keys) }

    public func existingHost(for tabId: String) -> TerminalHostView? {
        hosts[tabId]
    }

    /// The tab's terminal body, built on first use. `tabName` updates the identifiers when it changed.
    public func host(for tabId: String, tabName: String) -> TerminalHostView {
        if let host = hosts[tabId] {
            if host.tabName != tabName { host.tabName = tabName }
            return host
        }
        let host = TerminalHostView(tabId: tabId, tabName: tabName, identifiers: identifiers) { [unowned self] in
            self.makeSurface(tabId: tabId)
        }
        hosts[tabId] = host
        return host
    }

    /// Stops the tab's surface and forgets it. Call when the tab closes.
    public func close(_ tabId: String) {
        detachTasks.removeValue(forKey: tabId)?.cancel()
        guard let host = hosts.removeValue(forKey: tabId) else { return }
        host.close()
        host.removeFromSuperview()
    }

    /// Stops every surface, for app termination.
    public func closeAll() {
        for tabId in Array(hosts.keys) { close(tabId) }
    }

    /// Tells every host whether it is on screen: `visible` holds the tabs in the shown workspace's panes.
    /// A host hidden for `detachDelay` frees its surface; showing it again rebuilds the surface, and the
    /// daemon's replay repaints it.
    public func updateVisibility(visible: Set<String>) {
        for (tabId, host) in hosts {
            if visible.contains(tabId) {
                detachTasks.removeValue(forKey: tabId)?.cancel()
                host.setVisible(true)
            } else if detachTasks[tabId] == nil, !host.isSuspended {
                host.setVisible(false)
                let delay = detachDelay
                detachTasks[tabId] = Task { [weak self, weak host] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.detachTasks[tabId] = nil
                    host?.suspend()
                }
            }
        }
    }

    /// View › Bigger, Smaller and Actual Size (UX §8): every terminal, now and later, in memory only.
    public func setFontSize(_ size: Double) {
        settings.fontSize = size
        for host in hosts.values {
            (host.surface as? SwiftTermSurfaceView)?.setFontSize(size)
        }
    }

    /// Hosts whose surface is live (not suspended), for diagnostics.
    public var liveTabIds: [String] {
        hosts.filter { !$0.value.isSuspended }.map(\.key)
    }

    /// Updates `isDaemonReachable` on every body (UX §4.3 "Waiting for mapod…").
    public func setDaemonReachable(_ reachable: Bool) {
        for host in hosts.values { host.isDaemonReachable = reachable }
    }

    private func makeSurface(tabId: String) -> any TerminalSurface {
        switch settings.engine {
        case .ghostty:
            // GhosttyKit isn't linked on this build (PLAN T0.8 fallback); SwiftTerm stands in.
            return SwiftTermSurfaceView(tabId: tabId, launch: launch(tabId), settings: settings)
        case .swiftterm:
            return SwiftTermSurfaceView(tabId: tabId, launch: launch(tabId), settings: settings)
        }
    }
}
