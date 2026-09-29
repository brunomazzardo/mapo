import AppKit

/// Terminal bodies by tab id. A body lives until its tab closes, so re-layout, pane moves and zoom
/// re-host the same view instead of building a new surface (PLAN T0.8).
public final class SurfaceRegistry {
    public let settings: TerminalSettings
    private let launch: (_ tabId: String) -> TerminalLaunch
    private var hosts: [String: TerminalHostView] = [:]

    /// - Parameter launch: the process for a tab's surface, normally `TerminalLaunch.attach`.
    public init(settings: TerminalSettings, launch: @escaping (_ tabId: String) -> TerminalLaunch) {
        self.settings = settings
        self.launch = launch
    }

    /// The registry the app uses: every surface runs `<APP>/Contents/Helpers/mapo attach`.
    public convenience init(settings: TerminalSettings, instance: String, bundle: Bundle = .main) {
        let helper = TerminalLaunch.helperURL(in: bundle)
        self.init(settings: settings) { TerminalLaunch.attach(helper: helper, tabId: $0, instance: instance) }
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
        let host = TerminalHostView(tabId: tabId, tabName: tabName) { [unowned self] in
            self.makeSurface(tabId: tabId)
        }
        hosts[tabId] = host
        return host
    }

    /// Stops the tab's surface and forgets it. Call when the tab closes.
    public func close(_ tabId: String) {
        guard let host = hosts.removeValue(forKey: tabId) else { return }
        host.close()
        host.removeFromSuperview()
    }

    /// Stops every surface, for app termination.
    public func closeAll() {
        for tabId in Array(hosts.keys) { close(tabId) }
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
