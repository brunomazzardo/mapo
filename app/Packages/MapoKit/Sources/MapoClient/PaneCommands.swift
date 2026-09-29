import Foundation
import MapoProtocol

// MARK: - Commands the panes area and the Pane menu call (UX §4.2, PROTOCOL §6.4)

extension MapoClient {
    nonisolated private struct SplitParams: Encodable, Sendable {
        var pane: String?
        var direction: String
        var content: String
    }

    nonisolated private struct PaneParams: Encodable, Sendable {
        var pane: String?
        var split: String?
    }

    nonisolated private struct FocusParams: Encodable, Sendable {
        var pane: String?
        var direction: String?
    }

    nonisolated private struct ResizeParams: Encodable, Sendable {
        var split: String
        var ratios: [Double]
    }

    nonisolated private struct VisibilityParams: Encodable, Sendable {
        var keyWindow: Bool
        var visibleTabIds: [String]
        var focusedTabId: String?
    }

    /// Split Right (⌘D) or Split Down (⇧⌘D): a new shell in the focused pane's folder, focused.
    public func splitPane(direction: String, pane: String? = nil) async throws {
        _ = try await call(
            "pane.split", SplitParams(pane: pane, direction: direction, content: "new-shell"), as: Layout.self)
    }

    /// Close Pane (⌘W): the tab keeps running.
    public func closePane(id: String? = nil) async throws {
        _ = try await call("pane.close", PaneParams(pane: id), as: Layout.self)
    }

    public func focusPane(id: String) async throws {
        _ = try await call("pane.focus", FocusParams(pane: id), as: Layout.self)
    }

    /// ⌥⌘ plus an arrow: `left`, `right`, `up` or `down`.
    public func focusPane(direction: String) async throws {
        _ = try await call("pane.focus", FocusParams(direction: direction), as: Layout.self)
    }

    public func resizeSplit(id: String, ratios: [Double]) async throws {
        _ = try await call("pane.resize", ResizeParams(split: id, ratios: ratios), as: Layout.self)
    }

    /// Equalize Panes, or one split when `split` is set (double-click on a gutter).
    public func equalizePanes(split: String? = nil) async throws {
        _ = try await call("pane.equalize", PaneParams(split: split), as: Layout.self)
    }

    /// A new tab shown in `pane` (the empty pane's buttons): focus the pane, then create the tab there.
    public func newTab(inPane pane: String, kind: String) async throws {
        _ = try await call("pane.focus", FocusParams(pane: pane), as: Layout.self)
        _ = try await call(
            Method.tabCreate, TabCreateParams(kind: kind, placement: "focused", focus: true), as: TabSummary.self)
    }

    /// `ui.visibility`: what the app shows, for the done and failed rules (PROTOCOL §6.8).
    public func reportVisibility(keyWindow: Bool, visibleTabIds: [String], focusedTabId: String?) async throws {
        _ = try await call(
            "ui.visibility",
            VisibilityParams(keyWindow: keyWindow, visibleTabIds: visibleTabIds, focusedTabId: focusedTabId),
            as: JSONValue.self)
    }
}
