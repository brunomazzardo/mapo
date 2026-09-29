import AppKit

/// The UX §9.1 color tokens the M0 views use, resolving dark and light appearances. T1.9 completes the set
/// and adds the high-contrast variants.
public enum Tokens {
    public static let textPrimary = color("text.primary", dark: 0xF2F3F6, light: 0x16181D)
    public static let textBody = color("text.body", dark: 0xD5D8DF, light: 0x2B2E36)
    public static let textSecondary = color("text.secondary", dark: 0x9EA3AE, light: 0x5E6470)
    public static let textSecondaryOnSelection = color("text.secondaryOnSelection", dark: 0xC3C7D0, light: 0x5E6470)
    public static let icon = color("icon", dark: 0xA3A8B3, light: 0x636977)
    public static let iconSelected = color("icon.selected", dark: 0xDCE3F2, light: 0x16181D)
    public static let accent = color("accent", dark: 0x8AB0FF, light: 0x2F6BE0)
    public static let needs = color("needs", dark: 0xE8B557, light: 0x8F5B00)
    public static let needsTint = color("needs.tint", dark: 0xF1CB86, light: 0x6E4600)
    public static let needsFill = color("needs.fill", dark: 0xE8B557, light: 0xE8B557)
    public static let failed = color("failed", dark: 0xF47067, light: 0xB42F28)
    public static let failedTint = color("failed.tint", dark: 0xF6C9C5, light: 0x9A221B)
    public static let running = color("running", dark: 0x6CA8FF, light: 0x2563C9)
    public static let done = color("done", dark: 0x6FCF97, light: 0x177040)
    public static let stopped = color("stopped", dark: 0x858A98, light: 0x8A8F99)
    public static let pane = color("pane", dark: 0x1D1F25, light: 0xFFFFFF)
    public static let paneHairline = color("paneHairline", dark: (0xFFFFFF, 0.07), light: (0x000000, 0.08))
    public static let hover = color("hover", dark: (0xFFFFFF, 0.05), light: (0x000000, 0.04))
    public static let pressed = color("pressed", dark: (0xFFFFFF, 0.08), light: (0x000000, 0.07))
    public static let selection = color("selection", dark: (0x8AB0FF, 0.16), light: (0x2F6BE0, 0.14))
    public static let backdropTop = color("backdrop.top", dark: 0x25272E, light: 0xF4F5F8)
    public static let backdropBottom = color("backdrop.bottom", dark: 0x1F2127, light: 0xE9EBEF)
    /// Text on `needs.fill`, such as the workspace badge.
    public static let onNeedsFill = rgb(0x1D1F25)

    public static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func color(_ name: String, dark: UInt32, light: UInt32) -> NSColor {
        color(name, dark: (dark, 1), light: (light, 1))
    }

    private static func color(
        _ name: String, dark: (hex: UInt32, alpha: CGFloat), light: (hex: UInt32, alpha: CGFloat)
    ) -> NSColor {
        let darkColor = rgb(dark.hex, alpha: dark.alpha)
        let lightColor = rgb(light.hex, alpha: light.alpha)
        return NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}
