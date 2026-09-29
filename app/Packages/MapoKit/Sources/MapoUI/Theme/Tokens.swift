import AppKit

/// Earlier code calls the palette `Tokens`; both names work.
public typealias Tokens = Theme

/// Mapo Glass (UX §9): every §9.1 color token as a dynamic `NSColor` that resolves dark and light and,
/// under Increase Contrast, the high-contrast values of §9.1's last paragraph. Radii, spacing and the focus
/// ring come from §9.2. `Theme.apply(_:)` (Appearance.swift) sets the app's appearance and the accessibility
/// state the tokens and views read.
///
/// Colors resolve when they are drawn, so a view that copies one into a `CGColor` must do it inside
/// `effectiveAppearance.performAsCurrentDrawingAppearance` and again in `viewDidChangeEffectiveAppearance`.
public enum Theme {
    // MARK: Backdrop and materials

    /// The window backdrop's vertical gradient, top then bottom.
    public static let backdropTop = color("backdrop.top", dark: 0x25272E, light: 0xF4F5F8)
    public static let backdropBottom = color("backdrop.bottom", dark: 0x1F2127, light: 0xE9EBEF)
    /// The backdrop's radial glows, top left and bottom right.
    public static let backdropGlowTopLeading = color(
        "backdrop.glow.topLeading", dark: (0x7DA6FF, 0.13), light: (0x2F6BE0, 0.08))
    public static let backdropGlowBottomTrailing = color(
        "backdrop.glow.bottomTrailing", dark: (0xAC8CFF, 0.09), light: (0x7C4DDB, 0.06))

    /// Custom glass fill, used with blur 28 and saturate 160%. The rail and inspector take system glass.
    public static let glass = color("glass", dark: (0x2B2E36, 0.62), light: (0xFFFFFF, 0.62))
    /// Glass under Reduce Transparency (UX §9.4).
    public static let glassOpaque = color("glass.opaque", dark: 0x2B2E36, light: 0xF7F8FA)
    /// Glass edges: the border. Increase Contrast raises it.
    public static let hairline = color(
        "hairline", dark: (0xFFFFFF, 0.08), light: (0x000000, 0.08),
        highContrast: ((0xFFFFFF, 0.24), (0x000000, 0.28)))
    /// Glass edges: the inset top highlight.
    public static let highlight = color("highlight", dark: (0xFFFFFF, 0.06), light: (0xFFFFFF, 0.70))
    /// The palette, banner and notice fill, used with blur 30 and saturate 170%.
    public static let overlay = color("overlay", dark: (0x2C2F37, 0.80), light: (0xFAFAFC, 0.82))
    /// The overlay under Reduce Transparency (UX §9.4), drawn with a `hairline` border.
    public static let overlayOpaque = color("overlay.opaque", dark: 0x2C2F37, light: 0xFBFBFC)

    // MARK: Panes

    /// Pane cards and the terminal and editor background.
    public static let pane = color("pane", dark: 0x1D1F25, light: 0xFFFFFF)
    /// The pane border.
    public static let paneHairline = color(
        "paneHairline", dark: (0xFFFFFF, 0.07), light: (0x000000, 0.08),
        highContrast: ((0xFFFFFF, 0.24), (0x000000, 0.28)))
    /// The rule below a pane header and above a bar.
    public static let paneDivider = color(
        "paneDivider", dark: (0xFFFFFF, 0.06), light: (0x000000, 0.06),
        highContrast: ((0xFFFFFF, 0.24), (0x000000, 0.28)))

    // MARK: Fills

    public static let hover = color("hover", dark: (0xFFFFFF, 0.05), light: (0x000000, 0.04))
    public static let pressed = color("pressed", dark: (0xFFFFFF, 0.08), light: (0x000000, 0.07))
    /// Text button fill.
    public static let control = color("control", dark: (0xFFFFFF, 0.07), light: (0x000000, 0.05))
    /// The current row where it isn't selected, such as the palette's highlighted row.
    public static let rowCurrent = color("rowCurrent", dark: (0xFFFFFF, 0.08), light: (0x000000, 0.06))
    /// Selected rows in the rail, the tree and the palette. Increase Contrast doubles the alpha.
    public static let selection = color(
        "selection", dark: (0x8AB0FF, 0.16), light: (0x2F6BE0, 0.14),
        highContrast: ((0x8AB0FF, 0.32), (0x2F6BE0, 0.28)))

    // MARK: Text and glyphs

    public static let textPrimary = color("text.primary", dark: 0xF2F3F6, light: 0x16181D)
    public static let textBody = color("text.body", dark: 0xD5D8DF, light: 0x2B2E36)
    /// Metadata. Increase Contrast renders it as `text.body`.
    public static let textSecondary = color(
        "text.secondary", dark: (0x9EA3AE, 1), light: (0x5E6470, 1),
        highContrast: ((0xD5D8DF, 1), (0x2B2E36, 1)))
    /// `text.secondary` on a selected row.
    public static let textSecondaryOnSelection = color(
        "text.secondaryOnSelection", dark: 0xC3C7D0, light: 0x5E6470)
    /// Disabled and ignored rows.
    public static let textDisabled = color("text.disabled", dark: 0x6E7380, light: 0x8A8F99)
    public static let icon = color("icon", dark: 0xA3A8B3, light: 0x636977)
    public static let iconSelected = color("icon.selected", dark: 0xDCE3F2, light: 0x16181D)
    /// The kind icon in a focused pane's header (UX §4.1). Light is derived: `text.body`.
    public static let iconFocused = color("icon.focused", dark: 0xC3CBDB, light: 0x2B2E36)
    /// Editor and diff gutters.
    public static let lineNumber = color("lineNumber", dark: 0x858A98, light: 0x6F7582)

    // MARK: Accent and buttons

    /// The focus ring, links and match highlights.
    public static let accent = color("accent", dark: 0x8AB0FF, light: 0x2F6BE0)
    /// Primary buttons, with `onButtonPrimary` text.
    public static let buttonPrimary = color("button.primary", dark: 0x4A70D6, light: 0x2F63D0)
    public static let onButtonPrimary = rgb(0xFFFFFF)

    // MARK: Status

    public static let needs = color("needs", dark: 0xE8B557, light: 0x8F5B00)
    public static let needsTint = color("needs.tint", dark: 0xF1CB86, light: 0x6E4600)
    public static let needsFill = color("needs.fill", dark: 0xE8B557, light: 0xE8B557)
    /// Text on `needs.fill`, such as the workspace badge and the "Needs you" pill.
    public static let onNeedsFill = rgb(0x1D1F25)
    public static let failed = color("failed", dark: 0xF47067, light: 0xB42F28)
    public static let failedTint = color("failed.tint", dark: 0xF6C9C5, light: 0x9A221B)
    /// A failed pane's border.
    public static let failedBorder = color("failed.border", dark: (0xF47067, 0.35), light: (0xB42F28, 0.35))
    public static let running = color("running", dark: 0x6CA8FF, light: 0x2563C9)
    /// Done, and the serving dot.
    public static let done = color("done", dark: 0x6FCF97, light: 0x177040)
    public static let stopped = color("stopped", dark: 0x858A98, light: 0x8A8F99)
    /// macOS draws the dock badge; this is its color, for reference.
    public static let dockBadge = rgb(0xD92D24)

    // MARK: Diff and editor

    public static let diffAddedBg = color("diff.addedBg", dark: (0x6FCF97, 0.14), light: (0x22A05A, 0.14))
    public static let diffAddedText = color("diff.addedText", dark: 0xCFEFD9, light: 0x13522E)
    public static let diffRemovedBg = color("diff.removedBg", dark: (0xF47067, 0.14), light: (0xD64037, 0.12))
    public static let diffRemovedText = color("diff.removedText", dark: 0xF6C9C5, light: 0x8C1D17)
    public static let diffHunk = color("diff.hunk", dark: 0x9EA3AE, light: 0x5E6470)
    public static let diffHunkBg = color("diff.hunkBg", dark: (0xFFFFFF, 0.03), light: (0x000000, 0.03))
    public static let editorSelection = color("editor.selection", dark: (0x7DA6FF, 0.25), light: (0x2F6BE0, 0.20))
    public static let editorCurrentLine = color(
        "editor.currentLine", dark: (0xFFFFFF, 0.03), light: (0x000000, 0.03))

    // MARK: Syntax (tree-sitter captures)

    public static let syntaxKeyword = color("syntax.keyword", dark: 0xC3A6FF, light: 0x7A3FD1)
    public static let syntaxString = color("syntax.string", dark: 0xA6D98C, light: 0x3B7A1A)
    public static let syntaxFunction = color("syntax.function", dark: 0x8AB0FF, light: 0x2456C8)
    public static let syntaxType = color("syntax.type", dark: 0x7FD1C7, light: 0x0B7468)
    public static let syntaxNumber = color("syntax.number", dark: 0xE8B557, light: 0x8F5B00)
    public static let syntaxPunctuation = color("syntax.punctuation", dark: 0xA3A8B3, light: 0x5E6470)
    /// Comments keep the canvas value; Increase Contrast raises them (UX §9.1).
    public static let syntaxComment = color(
        "syntax.comment", dark: (0x7E8391, 1), light: (0x6A7080, 1),
        highContrast: ((0x9EA3AE, 1), (0x4F5561, 1)))

    // MARK: Radii, spacing and the focus ring (UX §9.2)

    public enum Radius {
        /// Glass panels, the palette and custom glass.
        public static let glass: CGFloat = 14
        public static let pane: CGFloat = 12
        public static let paletteRow: CGFloat = 8
        /// Rail, tree and change rows, header buttons, chips and bars.
        public static let row: CGFloat = 6
        public static let renameField: CGFloat = 4
        public static let hunkBar: CGFloat = 2
    }

    /// The named steps of the 2, 4, 6, 8, 10, 12, 16, 24 scale.
    public enum Spacing {
        /// Pane gutters and list insets.
        public static let gutter: CGFloat = 8
        /// Row padding and the panes area margin.
        public static let rowPadding: CGFloat = 10
        /// Header and bar padding.
        public static let headerPadding: CGFloat = 12
        public static let inspectorHeader: CGFloat = 16
    }

    /// The focus ring's width: 1.5, or 2 under Increase Contrast.
    public static var focusRingWidth: CGFloat { increaseContrast ? 2 : 1.5 }

    // MARK: Building colors

    public static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private typealias Value = (hex: UInt32, alpha: CGFloat)

    private static func color(_ name: String, dark: UInt32, light: UInt32) -> NSColor {
        color(name, dark: (dark, 1), light: (light, 1))
    }

    /// A named dynamic color. `highContrast` holds the dark and light values under Increase Contrast, from
    /// the system's high-contrast appearances or the app's own reading of the setting.
    private static func color(
        _ name: String, dark: Value, light: Value, highContrast: (dark: Value, light: Value)? = nil
    ) -> NSColor {
        let darkColor = rgb(dark.hex, alpha: dark.alpha)
        let lightColor = rgb(light.hex, alpha: light.alpha)
        let contrast = highContrast.map {
            (dark: rgb($0.dark.hex, alpha: $0.dark.alpha), light: rgb($0.light.hex, alpha: $0.light.alpha))
        }
        return NSColor(name: NSColor.Name(name)) { appearance in
            let match = appearance.bestMatch(from: [
                .darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let isHighContrast =
                match == .accessibilityHighContrastDarkAqua || match == .accessibilityHighContrastAqua
                || AccessibilityState.increaseContrast
            if let contrast, isHighContrast { return isDark ? contrast.dark : contrast.light }
            return isDark ? darkColor : lightColor
        }
    }
}
