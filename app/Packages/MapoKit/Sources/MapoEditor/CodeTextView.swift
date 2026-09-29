import AppKit

/// Line starts of a text, in UTF-16 offsets, for line numbers and Go to Line.
struct LineIndex {
    /// Offsets where each line starts; the first is 0. A text ending in a newline has an empty last line.
    private(set) var starts: [Int] = [0]

    init(_ text: NSString = "") {
        rebuild(text)
    }

    mutating func rebuild(_ text: NSString) {
        var starts = [0]
        let length = text.length
        starts.reserveCapacity(length / 30 + 1)
        var from = 0
        while from < length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: from, length: length - from))
            guard found.location != NSNotFound else { break }
            starts.append(found.location + 1)
            from = found.location + 1
        }
        self.starts = starts
    }

    var count: Int { starts.count }

    /// The zero-based line holding `offset`.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The offset of zero-based `line`, clamped.
    func start(of line: Int) -> Int {
        starts[max(0, min(line, starts.count - 1))]
    }
}

/// What the text view asks of its editor: commands with their own key equivalents, so they work before and
/// without a menu item (UX §8), and whichever pane is focused.
@MainActor
protocol CodeTextViewCommands: AnyObject {
    func save()
    func showGoToLine()
    func toggleSoftWrap()
    func toggleLineNumbers()
    var softWrap: Bool { get }
    var showsLineNumbers: Bool { get }
}

/// The editor's text view: TextKit 2 (`NSTextView(usingTextLayoutManager: true)`), the find bar, Tab as the
/// file's indent, and the keys of UX §8 that act on a focused file pane: ⌘S, ⌘L, ⌘F, ⌥⌘F, ⌘G, ⇧⌘G.
final class CodeTextView: NSTextView {
    weak var commands: CodeTextViewCommands?
    var indent = "    "
    var theme = EditorTheme.system
    /// Called when focus or the selection changes, so the current line can redraw.
    var onFocusChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { updateSelectionColor(active: true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { updateSelectionColor(active: false) }
        return resigned
    }

    /// The selection is `editor.selection`, at 60% while the text view isn't focused (UX §6.1).
    func updateSelectionColor(active: Bool) {
        let color = active ? theme.selection : theme.selection.withAlphaComponent(0.6)
        selectedTextAttributes = [.backgroundColor: color]
        onFocusChange?()
    }

    var isFocused: Bool {
        window?.firstResponder === self
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable else { return super.insertTab(sender) }
        insertText(indent, replacementRange: selectedRange())
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isFocused, handleCommand(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleCommand(event) { return }
        super.keyDown(with: event)
    }

    /// The editor's own chords. Returns false for anything else.
    private func handleCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        switch (key, flags) {
        case ("s", [.command]):
            commands?.save()
        case ("l", [.command]):
            commands?.showGoToLine()
        case ("f", [.command]):
            finderAction(.showFindInterface)
        case ("f", [.command, .option]):
            finderAction(isEditable ? .showReplaceInterface : .showFindInterface)
        case ("g", [.command]):
            finderAction(.nextMatch)
        case ("g", [.command, .shift]):
            finderAction(.previousMatch)
        case ("e", [.command]):
            finderAction(.setSearchString)
        default:
            return false
        }
        return true
    }

    /// Runs an `NSTextFinder` action the way a Find menu item with that tag would.
    func finderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    // MARK: Responder actions (for menu items; UX §8)

    @objc func saveDocument(_ sender: Any?) { commands?.save() }
    @objc func goToLine(_ sender: Any?) { commands?.showGoToLine() }
    @objc func toggleSoftWrap(_ sender: Any?) { commands?.toggleSoftWrap() }
    @objc func toggleLineNumbers(_ sender: Any?) { commands?.toggleLineNumbers() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleSoftWrap(_:)):
            (item as? NSMenuItem)?.state = (commands?.softWrap ?? false) ? .on : .off
            return true
        case #selector(toggleLineNumbers(_:)):
            (item as? NSMenuItem)?.state = (commands?.showsLineNumbers ?? true) ? .on : .off
            return true
        case #selector(saveDocument(_:)):
            return isEditable
        case #selector(goToLine(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

/// The line-number gutter (UX §6.1): numbers right-aligned 14 pt before the text in `lineNumber`, the current
/// line's in `text.body`. Numbers come from the visible `NSTextLayoutFragment`s, so only what shows is drawn.
/// Width is `3 + max(34, digits × advance + 14)`; the 3 pt leading strip is where T4.3's hunk bars go.
final class LineNumberGutter: NSView {
    weak var textView: CodeTextView?
    var lines = LineIndex()
    var theme = EditorTheme.system {
        didSet { needsDisplay = true }
    }
    /// The gap between the gutter and the text (the text container's left inset).
    var textInset: CGFloat = 8

    override var isFlipped: Bool { true }

    /// The width for the current line count.
    var preferredWidth: CGFloat {
        let digits = CGFloat(String(max(lines.count, 1)).count)
        let advance = ("8" as NSString).size(withAttributes: [.font: theme.font]).width
        return 3 + max(34, digits * advance + 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        dirtyRect.fill()
        guard let textView, let layoutManager = textView.textLayoutManager,
            let content = layoutManager.textContentManager
        else { return }
        let visible = textView.visibleRect
        let originY = textView.textContainerOrigin.y
        let documentStart = content.documentRange.location
        let caret = textView.selectedRange().location
        let caretLine = lines.line(at: caret)
        let rightEdge = bounds.width + textInset - 14
        let normal: [NSAttributedString.Key: Any] = [.font: theme.font, .foregroundColor: theme.lineNumber]
        let current: [NSAttributedString.Key: Any] = [.font: theme.font, .foregroundColor: theme.currentLineNumber]
        let length = (textView.string as NSString).length

        func drawNumber(_ line: Int, lineTop: CGFloat, lineHeight: CGFloat) {
            let text = String(line + 1) as NSString
            let attributes = line == caretLine ? current : normal
            let size = text.size(withAttributes: attributes)
            let y = lineTop + originY - visible.minY + (lineHeight - size.height) / 2
            text.draw(at: NSPoint(x: rightEdge - size.width, y: y), withAttributes: attributes)
        }

        let start =
            layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visible.minY - originY)))?.rangeInElement
            .location ?? documentStart
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout, .ensuresExtraLineFragment]) {
            fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + originY > visible.maxY { return false }
            let offset = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            let line = lines.line(at: offset)
            let lineFragments = fragment.textLineFragments
            if let first = lineFragments.first {
                let bounds = first.typographicBounds
                drawNumber(line, lineTop: frame.minY + bounds.minY, lineHeight: max(bounds.height, theme.lineHeight))
            }
            // The empty last line after a trailing newline is an extra line fragment of the last paragraph.
            if lineFragments.count > 1, let last = lineFragments.last, last.characterRange.length == 0,
                fragment.rangeInElement.endLocation.isEqual(content.documentRange.endLocation), length > 0
            {
                let bounds = last.typographicBounds
                drawNumber(lines.count - 1, lineTop: frame.minY + bounds.minY, lineHeight: theme.lineHeight)
            }
            return true
        }
    }
}

/// The current-line band (UX §6.1): `editor.currentLine` behind the caret's line while the editor is focused
/// with nothing selected. A sibling under the text view in the clip view, so it scrolls with the text.
final class CurrentLineView: NSView {
    var color = NSColor.clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
