import AppKit
import MapoAutomation
import MapoClient
import MapoTerminal
import MapoUI

/// Owns the app lifecycle (PLAN T0.7 steps 1 and 5): resolves the instance through the bundled `mapo`,
/// writes the app pid file, opens the window and starts the daemon connection.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, MapoCommandActions {
    private let options = LaunchOptions(arguments: CommandLine.arguments)
    private let log = MapoLog.shared
    private var client: MapoClient?
    private var registry: SurfaceRegistry?
    private var automation: AutomationServer?
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

    /// Unsaved files ask first (UX §6.2).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileEditors.shouldTerminate(window: windowController?.window)
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
                instance: info, helper: helper, spawnDaemon: options.spawnDaemon, clientName: "Mapo/\(version)",
                version: version))
        let registry = SurfaceRegistry(
            settings: TerminalSettings(instanceDirectory: info.dataDirectory), instance: info.name,
            identifiers: AXID.terminal)
        FileEditors.configure(dataDirectory: info.dataDirectory)
        let metrics = UIMetrics(store: client.store) { [weak self] in self?.windowController?.window }
        let windowController = MainWindowController(client: client, registry: registry, metrics: metrics)
        // `ui.*` from the daemon (PLAN T0.9); set before connecting so `app.register` offers `ui`.
        let automation = AutomationServer(store: client.store, metrics: metrics) { [weak windowController] in
            windowController?.window
        }
        automation.snapshotModel = { [weak windowController] in windowController?.automationModel() ?? [:] }
        client.requestHandler = { [weak windowController] request in
            if request.method.hasPrefix("explorer."), let windowController {
                return await windowController.inspector.handleExplorer(request)
            }
            return await automation.handle(request)
        }
        self.client = client
        self.registry = registry
        self.automation = automation
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

    // MARK: Menu actions (UX §8), from `CommandTable`

    @objc func openSettings(_ sender: Any?) { windowController?.openSettings() }
    @objc func newWorkspace(_ sender: Any?) { windowController?.newWorkspace() }
    @objc func newShellTab(_ sender: Any?) { windowController?.newShellTab() }
    @objc func newAgentTab(_ sender: Any?) { windowController?.newAgentTab() }
    @objc func newTabInFolder(_ sender: Any?) { windowController?.newTabInFolder() }
    @objc func showFiles(_ sender: Any?) { windowController?.showInspector(.files) }
    @objc func showChanges(_ sender: Any?) { windowController?.showInspector(.changes) }
    @objc func togglePalette(_ sender: Any?) { windowController?.togglePalette() }
    @objc func biggerFont(_ sender: Any?) { windowController?.changeFontSize(by: 1) }
    @objc func smallerFont(_ sender: Any?) { windowController?.changeFontSize(by: -1) }
    @objc func actualSizeFont(_ sender: Any?) { windowController?.changeFontSize(by: nil) }
    @objc func previousWorkspace(_ sender: Any?) { windowController?.switchWorkspace(by: -1) }
    @objc func nextWorkspace(_ sender: Any?) { windowController?.switchWorkspace(by: 1) }
    @objc func renameWorkspace(_ sender: Any?) { windowController?.renameActiveWorkspace() }
    /// M2; the item stays disabled.
    @objc func setAgentCommand(_ sender: Any?) { NSSound.beep() }
    @objc func moveWorkspaceUp(_ sender: Any?) { windowController?.moveActiveWorkspace(by: -1) }
    @objc func moveWorkspaceDown(_ sender: Any?) { windowController?.moveActiveWorkspace(by: 1) }
    @objc func deleteWorkspace(_ sender: Any?) { windowController?.deleteActiveWorkspace() }
    @objc func nextTabNeedingYou(_ sender: Any?) { windowController?.focusNextAttentionTab() }
    @objc func previousTab(_ sender: Any?) { windowController?.switchTab(by: -1) }
    @objc func nextTab(_ sender: Any?) { windowController?.switchTab(by: 1) }
    @objc func goToTab(_ sender: Any?) { windowController?.goToTab((sender as? NSMenuItem)?.tag ?? 0) }
    @objc func renameTab(_ sender: Any?) { windowController?.renameFocusedTab() }
    @objc func interruptAgent(_ sender: Any?) { windowController?.interruptAgent() }
    @objc func stopCommand(_ sender: Any?) { windowController?.stopCommand() }
    @objc func closeTab(_ sender: Any?) { windowController?.closeFocusedTab() }
    @objc func splitRight(_ sender: Any?) { windowController?.splitPane("right") }
    @objc func splitDown(_ sender: Any?) { windowController?.splitPane("down") }
    @objc func focusPaneLeft(_ sender: Any?) { windowController?.focusPane("left") }
    @objc func focusPaneRight(_ sender: Any?) { windowController?.focusPane("right") }
    @objc func focusPaneUp(_ sender: Any?) { windowController?.focusPane("up") }
    @objc func focusPaneDown(_ sender: Any?) { windowController?.focusPane("down") }
    @objc func equalizePanes(_ sender: Any?) { windowController?.equalizePanes() }
    @objc func closePane(_ sender: Any?) { windowController?.closePane() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        windowController?.validate(menuItem) ?? false
    }
}
