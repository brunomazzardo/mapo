import AppKit
import MapoClient
import MapoTerminal

/// `config.toml [ui] appearance` and `reduce-transparency` (PLAN T1.9). They let a drive capture every
/// variant without touching system settings. Read at launch.
nonisolated public struct AppearanceSettings: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case system, dark, light
    }

    public enum Override: String, Sendable {
        case system, on, off
    }

    public var appearance = Mode.system
    public var reduceTransparency = Override.system

    public init() {}

    /// Reads `[ui]` from `config.toml` text, keeping the defaults for missing or unknown values.
    public init(configTOML text: String) {
        self.init()
        let table = TOMLSubset.table(named: "ui", in: text)
        if case .string(let s) = table["appearance"], let mode = Mode(rawValue: s) { appearance = mode }
        if case .string(let s) = table["reduce-transparency"], let value = Override(rawValue: s) {
            reduceTransparency = value
        }
    }

    /// Reads `config.toml` from an instance directory; defaults when the file is missing or unreadable.
    public init(instanceDirectory: URL) {
        let url = instanceDirectory.appending(component: "config.toml")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            self.init(configTOML: text)
        } else {
            self.init()
        }
    }
}

/// Increase Contrast as the color providers see it. Written on the main thread only.
nonisolated enum AccessibilityState {
    nonisolated(unsafe) static var increaseContrast = false
}

extension Theme {
    /// Posted after the accessibility display options change and the theme re-applied them (UX §9.3).
    public static let didChangeNotification = Notification.Name("MapoThemeDidChange")

    public private(set) static var settings = AppearanceSettings()
    private static var accessibilityObserver: NSObjectProtocol?

    /// Reduce Transparency: the `[ui]` override, else the system setting. Glass Mapo draws itself (the
    /// palette, banner and notice) switches to its opaque fallback (UX §9.4); the rail and inspector get an
    /// opaque `glassOpaque` fill when the override asks for it and the system doesn't.
    public static var reduceTransparency: Bool {
        switch settings.reduceTransparency {
        case .on: true
        case .off: false
        case .system: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
    }

    /// Whether Mapo, not macOS, has to make the system glass opaque: the override is on, the system is off.
    public static var forcesOpaqueGlass: Bool {
        settings.reduceTransparency == .on && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    public static var increaseContrast: Bool { AccessibilityState.increaseContrast }

    /// The resolved appearance name for `ui.window` and logs: "dark" or "light".
    public static func appearanceName(of appearance: NSAppearance) -> String {
        let match = appearance.bestMatch(from: [
            .darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
        ])
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua ? "dark" : "light"
    }

    /// UX §9.3 durations; zero under Reduce Motion where the table says "Instant".
    public enum Motion {
        public static let hoverIn: TimeInterval = 0.12
        public static let hoverOut: TimeInterval = 0.08
        public static let expand: TimeInterval = 0.16
        public static let paletteOpen: TimeInterval = 0.14
        public static let paletteClose: TimeInterval = 0.10
        public static let fade: TimeInterval = 0.15

        /// `duration`, or 0 under Reduce Motion.
        public static func duration(_ duration: TimeInterval) -> TimeInterval {
            Theme.reduceMotion ? 0 : duration
        }
    }

    /// Sets the app's appearance from `settings` and starts following the accessibility display options.
    /// Call once at launch, before the window is built.
    public static func apply(_ settings: AppearanceSettings) {
        self.settings = settings
        refresh()
        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    refresh()
                    NotificationCenter.default.post(name: didChangeNotification, object: nil)
                }
            }
        }
        MapoLog.shared.info(
            "appearance \(settings.appearance.rawValue) reduceTransparency=\(reduceTransparency) "
                + "(\(settings.reduceTransparency.rawValue)) increaseContrast=\(increaseContrast) "
                + "reduceMotion=\(reduceMotion)")
    }

    /// Re-reads Increase Contrast and re-sets `NSApp.appearance`, so every view re-resolves its colors.
    private static func refresh() {
        let workspace = NSWorkspace.shared
        AccessibilityState.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        let contrast = AccessibilityState.increaseContrast
        switch settings.appearance {
        case .system:
            NSApp.appearance = nil
        case .dark:
            NSApp.appearance =
                (contrast ? NSAppearance(named: .accessibilityHighContrastDarkAqua) : nil)
                ?? NSAppearance(named: .darkAqua)
        case .light:
            NSApp.appearance =
                (contrast ? NSAppearance(named: .accessibilityHighContrastAqua) : nil) ?? NSAppearance(named: .aqua)
        }
    }
}
