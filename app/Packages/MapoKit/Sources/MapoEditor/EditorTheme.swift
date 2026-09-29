import AppKit

/// The colors and fonts the editor draws with (UX §6.1, §9). MapoUI builds it from its tokens, so this module
/// doesn't depend on the theme. Colors are dynamic `NSColor`s and resolve when drawn.
public struct EditorTheme {
    public var background: NSColor
    public var text: NSColor
    public var lineNumber: NSColor
    public var currentLineNumber: NSColor
    public var selection: NSColor
    public var currentLine: NSColor
    /// Bars at the top of the editor body (UX §6.2).
    public var barFill: NSColor
    public var barText: NSColor
    public var divider: NSColor
    /// The checkerboard behind image previews.
    public var checker: NSColor
    public var syntax: [SyntaxKind: NSColor]
    /// Git gutter bars (UX §6.1): added lines, modified lines and the deletion wedge.
    public var gitAdded: NSColor = .systemGreen
    public var gitModified: NSColor = .systemBlue
    public var gitDeleted: NSColor = .systemRed
    public var font: NSFont
    public var lineHeight: CGFloat

    public init(
        background: NSColor, text: NSColor, lineNumber: NSColor, currentLineNumber: NSColor, selection: NSColor,
        currentLine: NSColor, barFill: NSColor, barText: NSColor, divider: NSColor, checker: NSColor,
        syntax: [SyntaxKind: NSColor], gitAdded: NSColor = .systemGreen, gitModified: NSColor = .systemBlue,
        gitDeleted: NSColor = .systemRed,
        font: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular), lineHeight: CGFloat = 20
    ) {
        self.gitAdded = gitAdded
        self.gitModified = gitModified
        self.gitDeleted = gitDeleted
        self.background = background
        self.text = text
        self.lineNumber = lineNumber
        self.currentLineNumber = currentLineNumber
        self.selection = selection
        self.currentLine = currentLine
        self.barFill = barFill
        self.barText = barText
        self.divider = divider
        self.checker = checker
        self.syntax = syntax
        self.font = font
        self.lineHeight = lineHeight
    }

    /// A plain system palette, for tests and previews.
    public static let system = EditorTheme(
        background: .textBackgroundColor, text: .textColor, lineNumber: .secondaryLabelColor,
        currentLineNumber: .labelColor, selection: .selectedTextBackgroundColor,
        currentLine: NSColor.labelColor.withAlphaComponent(0.03), barFill: .controlBackgroundColor,
        barText: .labelColor, divider: .separatorColor, checker: NSColor.labelColor.withAlphaComponent(0.04),
        syntax: [:])

    /// The paragraph style that gives every line the theme's height, with the glyphs centered in it.
    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    /// Lifts glyphs so they sit in the middle of the fixed line height rather than at its bottom.
    var baselineOffset: CGFloat {
        let natural = font.ascender - font.descender
        return max(0, (lineHeight - natural) / 2)
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font, .foregroundColor: text, .paragraphStyle: paragraphStyle,
            .baselineOffset: baselineOffset,
        ]
    }
}

/// Accessibility identifiers of the editor (UX §2.4). They name files by absolute path.
public enum EditorAXID {
    /// `pane.file:<absPath>`: the file pane's body.
    public static func body(_ path: String) -> String { "pane.file:\(path)" }
    /// `editor:<absPath>`: the text view.
    public static func editor(_ path: String) -> String { "editor:\(path)" }
    /// `pane.preview:<absPath>`: an image or PDF preview.
    public static func preview(_ path: String) -> String { "pane.preview:\(path)" }
    public static func keepMine(_ path: String) -> String { "editor.keepMine:\(path)" }
    public static func reload(_ path: String) -> String { "editor.reload:\(path)" }
    public static func restore(_ path: String) -> String { "editor.restore:\(path)" }
    public static func discard(_ path: String) -> String { "editor.discard:\(path)" }
    public static func openDefault(_ path: String) -> String { "editor.openDefault:\(path)" }
    public static func reveal(_ path: String) -> String { "editor.reveal:\(path)" }
    public static func retrySave(_ path: String) -> String { "editor.retrySave:\(path)" }
    public static func close(_ path: String) -> String { "editor.close:\(path)" }
    /// The bar that holds the editor's current message; its value names the message kind.
    public static func bar(_ path: String) -> String { "editor.bar:\(path)" }
    /// `editor.gutter:<absPath>`: the git gutter; its value counts the hunks, such as "2 changed hunks".
    public static func gutter(_ path: String) -> String { "editor.gutter:\(path)" }
    /// `pane.diff:<absPath>`: a diff pane's body (UX §6.3).
    public static func diff(_ path: String) -> String { "pane.diff:\(path)" }
    /// `pane.openFile:<absPath>`: Open File in a diff pane.
    public static func openFile(_ path: String) -> String { "pane.openFile:\(path)" }
    /// The Go to Line field (⌘L).
    public static func goToLine(_ path: String) -> String { "editor.goToLine:\(path)" }
}
