import AppKit
import MapoClient
import MapoTerminal
import MapoUI

/// Owns the app lifecycle (PLAN T0.7 steps 1 and 5): resolves the instance through the bundled `mapo`,
/// writes the app pid file, opens the window and starts the daemon connection.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let options = LaunchOptions(arguments: CommandLine.arguments)
    private let log = MapoLog.shared
    private var client: MapoClient?
    private var registry: SurfaceRegistry?
    private var windowController: MainWindowController?
    private var pidFile: PidFile?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        installSignalHandlers()
        Task { await boot() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry?.closeAll()
        client?.stop()
        pidFile?.remove()
        log.info("exit")
        log.flush()
    }

    private func boot() async {
        let helper = MapoHelper.bundled()
        let info: InstanceInfo
        do {
            info = try await helper.instanceShow(instance: options.instance)
        } catch {
            log.error("can't resolve the instance: \(error)")
            fail("Mapo can't start", "The bundled mapo couldn't resolve the instance: \(error)")
            return
        }
        log.configure(directory: info.logDirectory)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        log.info(
            "launch pid=\(ProcessInfo.processInfo.processIdentifier) instance=\(info.name) source=\(info.source) "
                + "spawnDaemon=\(options.spawnDaemon) version=\(version)")

        let pidFile = PidFile(path: info.appPidFile)
        do {
            try pidFile.write()
            self.pidFile = pidFile
        } catch {
            log.warn("can't write \(info.appPidFile): \(error)")
        }

        let client = MapoClient(
            configuration: .init(
                instance: info, helper: helper, spawnDaemon: options.spawnDaemon, clientName: "Mapo/\(version)"))
        let registry = SurfaceRegistry(
            settings: TerminalSettings(instanceDirectory: info.dataDirectory), instance: info.name)
        let windowController = MainWindowController(client: client, registry: registry)
        self.client = client
        self.registry = registry
        self.windowController = windowController
        windowController.showWindow(nil)
        NSApp.activate()
        client.start()
    }

    /// Without an instance there is nothing to show; say why instead of a blank window, then quit.
    private func fail(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// SIGTERM and SIGINT quit through `terminate`, so the pid file goes away (`kill <pid>`, Ctrl-C).
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Menu actions (UX §8)

    @objc func newWorkspace(_ sender: Any?) {
        windowController?.newWorkspace()
    }

    @objc func newShellTab(_ sender: Any?) {
        windowController?.newShellTab()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newWorkspace(_:)), #selector(newShellTab(_:)):
            windowController?.isConnected ?? false
        default:
            true
        }
    }
}
