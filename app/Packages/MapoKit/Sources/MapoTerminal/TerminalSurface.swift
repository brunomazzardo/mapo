import AppKit

/// One terminal engine instance bound to one tab (ARCHITECTURE §4.3).
///
/// The surface's process is `mapo attach`, so the daemon owns the PTY and the surface is only a
/// renderer and input device. A surface starts its process when its view first joins a window, so the
/// first size the attach client reports is the real one. Implementations: `SwiftTermSurfaceView` now,
/// `GhosttySurfaceView` once GhosttyKit links (PLAN T0.8b).
@MainActor public protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    var tabId: String { get }
    /// Makes the surface the first responder, now or as soon as it joins a window.
    func focus()
    /// Tells the engine whether the surface is on screen, so it can stop rendering when hidden.
    func setVisible(_ visible: Bool)
    /// Stops the child process. The surface is dead afterwards; build a new one to reattach.
    func close()
    /// The title the program set (OSC 0/2). A UI hint only; the daemon is the source of truth.
    var onTitle: ((String) -> Void)? { get set }
    var onBell: (() -> Void)? { get set }
    /// Called once when the child exits on its own, with its exit code, or nil after an IO error.
    /// Not called after `close()`.
    var onExit: ((Int32?) -> Void)? { get set }
}

/// The process a surface runs, independent of the engine.
nonisolated public struct TerminalLaunch: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// Variables added to, or replacing, the app's own environment.
    public var environment: [String: String]
    public var currentDirectory: String?

    public init(
        executable: String, arguments: [String] = [], environment: [String: String] = [:],
        currentDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    /// `<helper> attach --tab <id> --instance <I>`, the only process a Mapo tab surface runs.
    /// The attach client reads the app token from the instance directory itself (ARCHITECTURE §4.3).
    public static func attach(helper: URL, tabId: String, instance: String) -> TerminalLaunch {
        TerminalLaunch(
            executable: helper.path, arguments: ["attach", "--tab", tabId, "--instance", instance],
            environment: ["MAPO_INSTANCE": instance, "TERM": "xterm-256color"])
    }

    /// A plain login shell, for scratch checks before `mapo attach` exists.
    public static func loginShell(_ shell: String = "/bin/zsh", in directory: String? = nil) -> TerminalLaunch {
        TerminalLaunch(
            executable: shell, arguments: ["-l"], environment: ["TERM": "xterm-256color"],
            currentDirectory: directory)
    }

    /// `<APP>/Contents/Helpers/mapo`.
    public static func helperURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appending(components: "Contents", "Helpers", "mapo")
    }

    /// The child's environment as `KEY=value` strings: the app's own environment, minus Mapo
    /// credentials the app itself may have inherited from a tab, plus `environment`.
    func resolvedEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var env = base
        for key in ["MAPO_TOKEN", "MAPO_HOOK_TOKEN", "MAPO_TAB_ID"] { env[key] = nil }
        // A Finder-launched app has no locale, and without one zsh and vim treat UTF-8 as bytes.
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.merge(environment) { _, new in new }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }
}
