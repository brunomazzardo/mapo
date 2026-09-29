import AppKit
import SwiftTerm

/// The SwiftTerm fallback engine (PLAN T0.8): a `LocalProcessTerminalView` running `launch` in a PTY.
///
/// Key equivalents: SwiftTerm doesn't override `performKeyEquivalent`, so every ⌘ chord reaches the
/// main menu first (UX §8), and `copy:`, `paste:` and `selectAll:` arrive through the Edit menu.
/// Resizing: SwiftTerm sets the PTY's window size on every frame change; `mapo attach` turns the
/// SIGWINCH into a RESIZE frame.
public final class SwiftTermSurfaceView: LocalProcessTerminalView, TerminalSurface {
    public let tabId: String
    public var onTitle: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onExit: ((Int32?) -> Void)?

    public var view: NSView { self }

    private let launch: TerminalLaunch
    private var started = false
    private var closed = false
    private var focusWhenInWindow = false
    // SwiftTerm's view already implements some `LocalProcessTerminalViewDelegate` names itself, so the
    // process callbacks go through a separate object.
    private let events = ProcessEvents()
    private var exitMonitor: DispatchSourceProcess?

    public init(tabId: String, launch: TerminalLaunch, settings: TerminalSettings) {
        self.tabId = tabId
        self.launch = launch
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        events.surface = self
        processDelegate = events
        font = Self.font(for: settings)
        optionAsMetaKey = settings.optionAsAlt
        applyTheme()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("SwiftTermSurfaceView is built in code")
    }

    // MARK: TerminalSurface

    public func focus() {
        guard let window else {
            focusWhenInWindow = true
            return
        }
        window.makeFirstResponder(self)
    }

    public func setVisible(_ visible: Bool) {
        // SwiftTerm draws on demand, so a hidden view costs nothing; nothing to pause.
        isHidden = !visible
    }

    public func close() {
        guard !closed else { return }
        closed = true
        exitMonitor?.cancel()
        exitMonitor = nil
        if started && process.running { terminate() }
        if started && process.shellPid > 0 {
            // SIGHUP from the closed PTY ends the child; reap it so it doesn't linger as a zombie.
            let pid = process.shellPid
            DispatchQueue.global().async {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
    }

    // MARK: Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if !started && !closed {
            started = true
            // The view's first real frame lands during this layout pass; start after it so the child
            // sees the pane's size, not the placeholder frame.
            DispatchQueue.main.async { [weak self] in self?.startChild() }
        }
        if focusWhenInWindow {
            focusWhenInWindow = false
            window?.makeFirstResponder(self)
        }
    }

    private func startChild() {
        guard !closed else { return }
        startProcess(
            executable: launch.executable, args: launch.arguments, environment: launch.resolvedEnvironment(),
            execName: nil, currentDirectory: launch.currentDirectory)
        watchChild(process.shellPid)
    }

    /// SwiftTerm 1.11 cancels its own exit monitor when the PTY reads EOF, which usually happens
    /// first, so it never reports the exit. Watch the pid here as well; whichever fires first wins.
    private func watchChild(_ pid: pid_t) {
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            let reaped = waitpid(pid, &status, WNOHANG) == pid
            MainActor.assumeIsolated { self?.childExited(reaped ? Self.exitCode(fromWaitStatus: status) : nil) }
        }
        source.activate()
        exitMonitor = source
    }

    /// `WEXITSTATUS`, or 128 + the signal number for a signaled child, as shells report it.
    nonisolated static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let theme = TerminalTheme.forAppearance(effectiveAppearance)
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        caretColor = theme.cursor
        selectedTextBackgroundColor = theme.selection
        installColors(
            theme.ansi.map {
                // 16-bit channels: 0xAB becomes 0xABAB.
                Color(
                    red: UInt16(($0 >> 16) & 0xFF) * 257, green: UInt16(($0 >> 8) & 0xFF) * 257,
                    blue: UInt16($0 & 0xFF) * 257)
            })
    }

    private static func font(for settings: TerminalSettings) -> NSFont {
        let size = CGFloat(settings.fontSize)
        if settings.fontFamily != "SF Mono",
            let font = NSFontManager.shared.font(withFamily: settings.fontFamily, traits: [], weight: 5, size: size)
        {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: SwiftTerm callbacks

    public override func bell(source: Terminal) {
        onBell?()
    }

    fileprivate func childExited(_ exitCode: Int32?) {
        guard !closed else { return }
        closed = true
        exitMonitor?.cancel()
        exitMonitor = nil
        onExit?(exitCode)
    }
}

private final class ProcessEvents: LocalProcessTerminalViewDelegate {
    weak var surface: SwiftTermSurfaceView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        surface?.onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // The daemon owns the cwd (ARCHITECTURE §4.3).
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // SwiftTerm passes the raw wait status.
        surface?.childExited(exitCode.map(SwiftTermSurfaceView.exitCode(fromWaitStatus:)))
    }
}
