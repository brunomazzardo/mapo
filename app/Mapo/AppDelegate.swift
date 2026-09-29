import AppKit
import MapoClient
import MapoUI

/// Owns the app lifecycle. T0.7 adds the window, the daemon connection and the menus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
