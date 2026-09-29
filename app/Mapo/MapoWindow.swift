import AppKit
import MapoUI

/// The one main window of an instance (UX §2): no visible title bar, content under a unified toolbar,
/// and no window restoration, because sessions come from the daemon.
final class MapoWindow: NSWindow {
    static let defaultSize = NSSize(width: 1440, height: 900)
    static let minimumSize = NSSize(width: 760, height: 480)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        toolbarStyle = .unified
        isRestorable = false
        tabbingMode = .disallowed
        minSize = Self.minimumSize
        isReleasedWhenClosed = false
        setAccessibilityIdentifier(AXID.windowMain)
    }
}
