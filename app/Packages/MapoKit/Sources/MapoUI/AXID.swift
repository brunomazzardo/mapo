import AppKit

/// Builds every accessibility identifier string (ENGINEERING §4.2 rule 1; UX §2.4). Views never spell
/// identifiers out. Names are stable names, never titles.
public enum AXID {
    public static let windowMain = "window.main"
    public static let rail = "rail"
    public static let railToggle = "rail.toggle"
    public static let railNewWorkspace = "rail.newWorkspace"
    public static let railEmptyNewWorkspace = "rail.empty.newWorkspace"
    public static let toolbarInspector = "toolbar.inspector"
    public static let inspector = "inspector"
    public static let appBanner = "app.banner"
    public static let appBannerAction = "app.banner.action"

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

    /// `pane.empty.newShell:<paneId>`.
    public static func paneEmptyNewShell(_ paneId: String) -> String {
        "pane.empty.newShell:\(paneId)"
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
