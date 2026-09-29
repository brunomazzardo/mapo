import AppKit
import MapoClient
import MapoProtocol
import MapoUI
import UserNotifications

/// Attention (PLAN T2.4, UX §7.3): the dock badge, notifications for tabs you can't see, and the order ⌘J
/// walks. Notifications are authorized lazily on the first one, identified `<instance>/<tabId>` so a newer
/// state replaces the older one and dev instances sharing `dev.mapo.app.dev` ignore each other's clicks.
/// Every posted or suppressed notification writes the ENGINEERING §4.2 `notification:<tabId>` log line.
final class AttentionController: NSObject, UNUserNotificationCenterDelegate {
    private let store: AppStore
    private let instance: String
    private let log = MapoLog.shared
    /// Whether the person can see the tab now (UX §7.3).
    private let canSee: (TabSummary) -> Bool
    /// `tab.focus` plus keyboard focus, for a clicked notification.
    private let focusTab: (String) -> Void
    /// The notifying state each tab was last notified for, posted or not, so a repeat coalesces.
    private var notified: [String: TabState] = [:]
    /// The last state seen per tab. `tab.updated` and `tab.state` both arrive for one change, in either
    /// order, and only the first counts. `tab.updated` also arrives for title and shell activity, so only a
    /// `tab.state` whose `previous` equals `state` (the daemon re-reporting a hook, such as a second
    /// PermissionRequest) counts as a repeat, which coalesces.
    private var seen: [String: TabState] = [:]
    /// When each tab last entered `running`, for "finished in 4 min".
    private var runningSince: [String: Date] = [:]
    /// Tabs whose notification waited on the authorization prompt; posted if the person allows.
    private var awaitingAuthorization: Set<String> = []
    private var authorization: UNAuthorizationStatus?
    private var isRequestingAuthorization = false

    /// The states that notify (UX §7.1). `[attention] notify` narrows them once config reaches the app.
    private static let notifying: Set<TabState> = [.needsYou, .failed, .done]

    init(
        client: MapoClient, canSee: @escaping (TabSummary) -> Bool, focusTab: @escaping (String) -> Void
    ) {
        self.store = client.store
        self.instance = client.store.instance
        self.canSee = canSee
        self.focusTab = focusTab
        super.init()
        UNUserNotificationCenter.current().delegate = self
        client.addEventListener { [weak self] event in self?.handle(event) }
        observeContinuously(self) { $0.updateDockBadge() }
    }

    /// Tabs in `needs-you` across all workspaces; the dock badge shows it (UX §7.3).
    var dockBadge: Int {
        store.tabs.values.count { $0.state == .needsYou }
    }

    private func updateDockBadge() {
        let count = dockBadge
        let label = count == 0 ? "" : count > 99 ? "99+" : String(count)
        if NSApp.dockTile.badgeLabel ?? "" != label { NSApp.dockTile.badgeLabel = label }
    }

    /// The tabs ⌘J walks: needs-you, then failed, then unviewed done, each in rail order (UX §7.4). Done
    /// clears on view in the daemon, so every done tab is unviewed.
    static func attentionOrder(_ store: AppStore) -> [TabSummary] {
        let railOrder = store.workspaces.flatMap { store.tabs(inWorkspace: $0.id) }
        return [TabState.needsYou, .failed, .done].flatMap { state in railOrder.filter { $0.state == state } }
    }

    /// The attention tab after `current`, wrapping; the first one when `current` isn't one.
    static func nextAttentionTab(_ store: AppStore, after current: String?) -> TabSummary? {
        let order = attentionOrder(store)
        guard !order.isEmpty else { return nil }
        guard let index = order.firstIndex(where: { $0.id == current }) else { return order[0] }
        return order[(index + 1) % order.count]
    }

    // MARK: Events

    private func handle(_ event: Event) {
        switch event.payload {
        case .tabState(let change):
            if change.state == .running { runningSince[change.tabId] = Date() }
            // A report of the state the tab already has (a second PermissionRequest) coalesces.
            evaluate(change.tabId, repeated: change.previous == change.state)
        case .tabCreated(let tab), .tabUpdated(let tab):
            evaluate(tab.id, repeated: false)
        case .tabClosed(let closed):
            clear(closed.id)
            seen[closed.id] = nil
            runningSince[closed.id] = nil
        case .workspaceDeleted:
            for id in notified.keys where store.tabs[id] == nil { clear(id) }
        default:
            break
        }
    }

    private func evaluate(_ tabId: String, repeated: Bool) {
        guard let tab = store.tabs[tabId] else { return }
        let changed = seen[tabId] != tab.state
        seen[tabId] = tab.state
        guard Self.notifying.contains(tab.state) else {
            clear(tabId)
            return
        }
        guard changed || repeated else { return }
        if notified[tabId] == tab.state {
            record(tab, shown: false, reason: "coalesced")
            return
        }
        if canSee(tab) {
            record(tab, shown: false, reason: "visible")
            return
        }
        notified[tabId] = tab.state
        Task { await post(tab) }
    }

    /// The attention cleared: withdraw its notification.
    private func clear(_ tabId: String) {
        guard notified.removeValue(forKey: tabId) != nil else { return }
        awaitingAuthorization.remove(tabId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(tabId)])
    }

    // MARK: Posting

    private func identifier(_ tabId: String) -> String { "\(instance)/\(tabId)" }

    private func post(_ tab: TabSummary) async {
        let center = UNUserNotificationCenter.current()
        if authorization == nil { authorization = await center.notificationSettings().authorizationStatus }
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            // The system prompt is the person's (ENGINEERING §10); post once they allow.
            awaitingAuthorization.insert(tab.id)
            requestAuthorization()
            record(tab, shown: false, reason: "unauthorized")
            return
        default:
            record(tab, shown: false, reason: "unauthorized")
            return
        }
        let request = UNNotificationRequest(identifier: identifier(tab.id), content: content(tab), trigger: nil)
        do {
            try await center.add(request)
            record(tab, shown: true, reason: "posted")
        } catch {
            log.warn("notification:\(tab.id) add failed: \(error)")
            record(tab, shown: false, reason: "unauthorized")
        }
    }

    private func requestAuthorization() {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        Task {
            let granted =
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]))
                ?? false
            isRequestingAuthorization = false
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            log.info("notifications authorized=\(granted)")
            let waiting = awaitingAuthorization
            awaitingAuthorization = []
            guard granted else { return }
            for id in waiting {
                guard let tab = store.tabs[id], notified[id] == tab.state, !canSee(tab) else { continue }
                await post(tab)
            }
        }
    }

    /// Title and body from the UX §7.3 table. Never terminal text.
    private func content(_ tab: TabSummary) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let name = tab.labeled || tab.title.isEmpty ? tab.name : tab.title
        let workspace = store.workspace(id: tab.workspaceId)?.name ?? ""
        let detail: String?
        switch tab.state {
        case .needsYou:
            content.title = "\(name) needs you"
            detail = tab.stateDetail
        case .failed where tab.launchError != nil:
            content.title = "\(name) couldn't start"
            detail = tab.launchError?.message
        case .failed:
            content.title = "\(name) failed"
            detail = tab.stateDetail ?? tab.lastExit.map { "exit \($0.code)" }
        default:
            content.title = "\(name) is done"
            detail = finishedIn(tab).map { "finished in \($0)" }
        }
        content.body = [workspace, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        // Needs-you and failed use the default sound; done is silent.
        if tab.state != .done { content.sound = .default }
        content.threadIdentifier = instance
        return content
    }

    /// "38 s", "4 min" or "1 h 12 min", from entering `running` or from the command's own duration.
    private func finishedIn(_ tab: TabSummary) -> String? {
        let seconds: Int
        if let started = runningSince[tab.id] {
            seconds = Int(Date().timeIntervalSince(started))
        } else if let ms = tab.lastExit?.durationMs {
            seconds = ms / 1000
        } else {
            return nil
        }
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }

    /// ENGINEERING §4.2: drives read this line, never the banner.
    private func record(_ tab: TabSummary, shown: Bool, reason: String) {
        log.info("notification:\(tab.id) state=\(tab.state.rawValue) shown=\(shown) reason=\(reason)")
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Mapo posts only for tabs you can't see, so a notification that arrives while Mapo is active still shows.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A click activates Mapo and runs `tab.focus`. Another dev instance's notifications are ignored.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run {
            let prefix = "\(instance)/"
            guard identifier.hasPrefix(prefix) else { return }
            let tabId = String(identifier.dropFirst(prefix.count))
            guard store.tabs[tabId] != nil else { return }
            NSApp.activate()
            focusTab(tabId)
        }
    }
}
