import AppKit

/// Builds every accessibility identifier string (ENGINEERING §4.2 rule 1; UX §2.4). Views never spell
/// identifiers out. Names are stable names, never titles.
public enum AXID {
    public static let windowMain = "window.main"
    public static let rail = "rail"
    public static let railToggle = "rail.toggle"
    public static let railNewWorkspace = "rail.newWorkspace"
    public static let railEmptyNewWorkspace = "rail.empty.newWorkspace"
    /// The inline rename field on a rail row (UX §3.4).
    public static let railRename = "rail.rename"
    public static let toolbarTitle = "toolbar.title"
    public static let toolbarInspector = "toolbar.inspector"
    public static let windowDividerRail = "window.divider:rail"
    public static let windowDividerInspector = "window.divider:inspector"
    public static let inspector = "inspector"
    public static let appBanner = "app.banner"
    public static let appBannerAction = "app.banner.action"
    /// A sheet on the main window and its buttons (UX §3.5), built by `ConfirmSheet`.
    public static let dialog = "dialog"
    public static let dialogConfirm = "dialog.confirm"
    public static let dialogCancel = "dialog.cancel"
    /// Don't Save in the unsaved-file sheets (UX §4.2, §6.2).
    public static let dialogDiscard = "dialog.discard"
    /// A sheet's text field, such as New Tab in Folder's path (UX §3.5).
    public static let dialogField = "dialog.field"
    /// The ⌘K palette (UX §10): its panel, its field, and `palette.row:<index>`.
    public static let palette = "palette"
    public static let paletteField = "palette.field"

    /// `palette.row:<index>`, zero-based in display order, headers skipped.
    public static func paletteRow(_ index: Int) -> String {
        "palette.row:\(index)"
    }

    /// `rail.workspace:<workspaceName>`.
    public static func railWorkspace(_ workspaceName: String) -> String {
        "rail.workspace:\(workspaceName)"
    }

    /// `rail.workspace.badge:<workspaceName>`.
    public static func railWorkspaceBadge(_ workspaceName: String) -> String {
        "rail.workspace.badge:\(workspaceName)"
    }

    /// `rail.tab:<workspaceName>/<tabName>`, with `%` and `/` inside either name escaped.
    public static func railTab(workspace workspaceName: String, tab tabName: String) -> String {
        "rail.tab:\(escape(workspaceName))/\(escape(tabName))"
    }

    /// `pane:<paneId>`.
    public static func pane(_ paneId: String) -> String {
        "pane:\(paneId)"
    }

    /// `pane.terminal:<tabName>`.
    public static func paneTerminal(_ tabName: String) -> String {
        "pane.terminal:\(tabName)"
    }

    /// `pane.reconnect:<tabName>`.
    public static func paneReconnect(_ tabName: String) -> String {
        "pane.reconnect:\(tabName)"
    }

    /// The identifiers `SurfaceRegistry` puts on a tab's surface and on its Reconnect button.
    public static func terminal(_ tabName: String) -> (terminal: String, reconnect: String) {
        (paneTerminal(tabName), paneReconnect(tabName))
    }

    /// `pane.empty.newShell:<paneId>`, or `pane.empty.newShell` in a workspace that has no layout yet (no tabs,
    /// so no pane id).
    public static func paneEmptyNewShell(_ paneId: String?) -> String {
        paneId.map { "pane.empty.newShell:\($0)" } ?? "pane.empty.newShell"
    }

    /// `pane.empty.newAgent:<paneId>`.
    public static func paneEmptyNewAgent(_ paneId: String?) -> String {
        paneId.map { "pane.empty.newAgent:\($0)" } ?? "pane.empty.newAgent"
    }

    /// `pane.header:<tabName>`, or `pane.header:<absPath>` for file and diff panes.
    public static func paneHeader(_ name: String) -> String {
        "pane.header:\(name)"
    }

    /// `pane.close:<paneId>`.
    public static func paneClose(_ paneId: String) -> String {
        "pane.close:\(paneId)"
    }

    /// `pane.recent:<paneId>`: the file pane's recent-files pull-down (UX §6.1).
    public static func paneRecent(_ paneId: String) -> String {
        "pane.recent:\(paneId)"
    }

    /// `pane.stop:<tabName>`.
    public static func paneStop(_ tabName: String) -> String {
        "pane.stop:\(tabName)"
    }

    /// `pane.restart:<tabName>`, on the exit bar of a stopped shell (UX §4.3).
    public static func paneRestart(_ tabName: String) -> String {
        "pane.restart:\(tabName)"
    }

    /// `pane.closeTab:<tabName>`, on the exit bar of a stopped shell (UX §4.3).
    public static func paneCloseTab(_ tabName: String) -> String {
        "pane.closeTab:\(tabName)"
    }

    /// `pane.divider:<splitId>/<index>`: the gutter after child `index` of a split (UX §2.4).
    public static func paneDivider(splitId: String, index: Int) -> String {
        "pane.divider:\(splitId)/\(index)"
    }

    /// Rule 2: `%` becomes `%25` first, then `/` becomes `%2F`, so the separator stays unambiguous.
    public static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }
}

extension NSControl {
    /// Sets the identifier on the control and on its cell, which AppKit exposes as the accessibility
    /// element of buttons and text fields.
    public func setAXIdentifier(_ identifier: String?) {
        setAccessibilityIdentifier(identifier)
        cell?.setAccessibilityIdentifier(identifier)
    }
}
