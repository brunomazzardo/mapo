import AppKit

/// The Mapo Glass terminal palette (UX §9.1), one per appearance.
struct TerminalTheme {
    var background: NSColor
    var foreground: NSColor
    var cursor: NSColor
    var selection: NSColor
    /// 16 ANSI colors: normal 0–7, then bright 8–15, as `0xRRGGBB`.
    var ansi: [UInt32]

    static let dark = TerminalTheme(
        background: rgb(0x1D1F25), foreground: rgb(0xD5D8DF), cursor: rgb(0xD5D8DF), selection: rgb(0x35415C),
        ansi: [
            0x2B2E36, 0xF47067, 0x6FCF97, 0xE8B557, 0x6CA8FF, 0xC3A6FF, 0x7FD1C7, 0xD5D8DF,
            0x6E7380, 0xF89A92, 0x9BE0B6, 0xF1CB86, 0xA6C3FF, 0xD8C5FF, 0xA8E3DC, 0xF2F3F6,
        ])

    static let light = TerminalTheme(
        background: rgb(0xFFFFFF), foreground: rgb(0x2B2E36), cursor: rgb(0x2B2E36), selection: rgb(0xD5E1F9),
        ansi: [
            0x2B2E36, 0xB42F28, 0x177040, 0x8F5B00, 0x2563C9, 0x7A3FD1, 0x0B7468, 0xC9CCD3,
            0x5E6470, 0xD0453D, 0x1F8F52, 0xA86E00, 0x2F6BE0, 0x9160E0, 0x13897B, 0x9A9FAA,
        ])

    static func forAppearance(_ appearance: NSAppearance) -> TerminalTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
