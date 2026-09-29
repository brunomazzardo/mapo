import AppKit

/// The diff pane's colors (UX §6.3, §9.1); MapoUI fills them from its tokens.
public struct DiffColors {
    public var context: NSColor
    public var hunk: NSColor
    public var hunkBackground: NSColor
    public var addedText: NSColor
    public var addedBackground: NSColor
    public var removedText: NSColor
    public var removedBackground: NSColor

    public init(
        context: NSColor, hunk: NSColor, hunkBackground: NSColor, addedText: NSColor, addedBackground: NSColor,
        removedText: NSColor, removedBackground: NSColor
    ) {
        self.context = context
        self.hunk = hunk
        self.hunkBackground = hunkBackground
        self.addedText = addedText
        self.addedBackground = addedBackground
        self.removedText = removedText
        self.removedBackground = removedBackground
    }
}

/// One line of a unified diff as the diff pane shows it.
struct DiffLine: Equatable {
    enum Kind: Equatable {
        case hunk
        case added
        case removed
        case context
        case note
    }

    var kind: Kind
    var text: String
    var old: Int?
    var new: Int?

    /// `git diff` output from the first `@@`: the `diff --git`, `index`, `---` and `+++` lines are dropped.
    static func parse(_ diff: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var old = 0
        var new = 0
        var inHunk = false
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHunk = true
                let (o, n) = hunkStarts(line)
                old = o
                new = n
                result.append(DiffLine(kind: .hunk, text: line))
                continue
            }
            if line.hasPrefix("diff --git") {
                inHunk = false
                continue
            }
            guard inHunk else {
                if line.hasPrefix("Binary files") { result.append(DiffLine(kind: .note, text: "Binary files differ.")) }
                continue
            }
            switch line.first {
            case "+":
                result.append(DiffLine(kind: .added, text: line, new: new))
                new += 1
            case "-":
                result.append(DiffLine(kind: .removed, text: line, old: old))
                old += 1
            case " ":
                result.append(DiffLine(kind: .context, text: line, old: old, new: new))
                old += 1
                new += 1
            case "\\":
                result.append(DiffLine(kind: .note, text: line))
            default:
                break
            }
        }
        return result
    }

    /// `@@ -12,7 +12,9 @@` → (12, 12).
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }
}

/// The unified diff pane (UX §6.3, R-GIT-2): a read-only text view over `git.diff` with full-width line
/// backgrounds, old and new line numbers, and Open File. The view is `pane.diff:<absPath>`; its value
/// counts hunks and lines, such as "2 hunks, +3 -1".
public final class DiffView: NSView {
    public let root: String
    public let path: String
    /// Reads the diff (`git.diff`).
    public var loader: (() async throws -> String)?
    /// Open File (`pane.openFile:<absPath>`).
    public var onOpenFile: (() -> Void)?

    private let theme: EditorTheme
    private let colors: DiffColors
    private let bar = NSView()
    private let barLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open File", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let text = DiffTextView(usingTextLayoutManager: false)
    private let gutter = DiffGutterView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var lines: [DiffLine] = []
    private var loadTask: Task<Void, Never>?
    private static let barHeight: CGFloat = 32

    public init(root: String, path: String, theme: EditorTheme, colors: DiffColors) {
        self.root = root
        self.path = path
        self.theme = theme
        self.colors = colors
        super.init(frame: .zero)
        wantsLayer = true

        bar.wantsLayer = true
        barLabel.font = .systemFont(ofSize: 12)
        barLabel.textColor = theme.barText
        barLabel.stringValue = "Changes against HEAD"
        openButton.bezelStyle = .accessoryBarAction
        openButton.controlSize = .small
        openButton.font = .systemFont(ofSize: 12)
        openButton.target = self
        openButton.action = #selector(openPressed)
        openButton.setAccessibilityIdentifier(EditorAXID.openFile(path))
        openButton.cell?.setAccessibilityIdentifier(EditorAXID.openFile(path))
        openButton.toolTip = "Open \((path as NSString).lastPathComponent) in the Editor"
        bar.addSubview(barLabel)
        bar.addSubview(openButton)

        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = true
        text.textContainerInset = NSSize(width: 0, height: 10)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.lineFragmentPadding = 8
        text.lineHeight = theme.lineHeight
        text.setAccessibilityLabel("Diff of \((path as NSString).lastPathComponent)")
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        gutter.textView = text
        gutter.font = theme.font
        gutter.lineHeight = theme.lineHeight
        gutter.numberColor = theme.lineNumber

        emptyLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        emptyLabel.textColor = theme.lineNumber
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        for view in [bar, gutter, scroll, emptyLabel] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(EditorAXID.diff(path))
        setAccessibilityLabel("\((path as NSString).lastPathComponent), diff")
        setAccessibilityValue("loading")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DiffView is built in code")
    }

    public override var isFlipped: Bool { true }

    /// Reads the diff again; a newer reload supersedes an older one.
    public func reload() {
        guard let loader else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await loader()) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let diff): show(DiffLine.parse(diff))
            case .failure(let error): showMessage("Couldn't read the diff: \(error)", value: "error")
            }
        }
    }

    private func show(_ parsed: [DiffLine]) {
        lines = parsed
        guard !parsed.isEmpty else { return showMessage("No changes against HEAD.", value: "no changes") }
        emptyLabel.isHidden = true
        scroll.isHidden = false
        gutter.isHidden = false
        let body = NSMutableAttributedString()
        let style = theme.paragraphStyle
        for (index, line) in parsed.enumerated() {
            let color: NSColor =
                switch line.kind {
                case .hunk: colors.hunk
                case .added: colors.addedText
                case .removed: colors.removedText
                case .context: colors.context
                case .note: theme.lineNumber
                }
            body.append(
                NSAttributedString(
                    string: line.text + (index == parsed.count - 1 ? "" : "\n"),
                    attributes: [
                        .font: theme.font, .foregroundColor: color, .paragraphStyle: style,
                        .baselineOffset: theme.baselineOffset,
                    ]))
        }
        text.textStorage?.setAttributedString(body)
        text.backgrounds = parsed.map { line in
            switch line.kind {
            case .hunk: colors.hunkBackground
            case .added: colors.addedBackground
            case .removed: colors.removedBackground
            case .context, .note: nil
            }
        }
        gutter.lines = parsed
        let hunks = parsed.filter { $0.kind == .hunk }.count
        let added = parsed.filter { $0.kind == .added }.count
        let removed = parsed.filter { $0.kind == .removed }.count
        setAccessibilityValue("\(hunks) \(hunks == 1 ? "hunk" : "hunks"), +\(added) -\(removed)")
        needsLayout = true
        text.needsDisplay = true
        gutter.needsDisplay = true
    }

    private func showMessage(_ message: String, value: String) {
        lines = []
        text.textStorage?.setAttributedString(NSAttributedString())
        text.backgrounds = []
        gutter.lines = []
        scroll.isHidden = true
        gutter.isHidden = true
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        setAccessibilityValue(value)
    }

    public override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        openButton.sizeToFit()
        let button = openButton.frame.size
        openButton.frame = NSRect(
            x: bounds.width - 12 - button.width, y: (Self.barHeight - button.height) / 2, width: button.width,
            height: button.height)
        barLabel.sizeToFit()
        barLabel.frame = NSRect(
            x: 12, y: (Self.barHeight - barLabel.frame.height) / 2,
            width: max(0, openButton.frame.minX - 24), height: barLabel.frame.height)
        let body = NSRect(x: 0, y: Self.barHeight, width: bounds.width, height: max(0, bounds.height - Self.barHeight))
        let gutterWidth = gutter.preferredWidth
        gutter.frame = NSRect(x: body.minX, y: body.minY, width: gutterWidth, height: body.height)
        scroll.frame = NSRect(
            x: body.minX + gutterWidth, y: body.minY, width: max(0, body.width - gutterWidth), height: body.height)
        text.minSize = NSSize(width: scroll.contentSize.width, height: scroll.contentSize.height)
        emptyLabel.frame = NSRect(x: 12, y: body.midY - 10, width: max(0, bounds.width - 24), height: 20)
        gutter.needsDisplay = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = theme.background.cgColor
            bar.layer?.backgroundColor = theme.barFill.cgColor
        }
        text.backgroundColor = theme.background
        gutter.background = theme.background
    }

    @objc private func scrolled() {
        gutter.needsDisplay = true
    }

    @objc private func openPressed() {
        onOpenFile?()
    }
}

/// The diff's text view: every line is `lineHeight` tall and doesn't wrap, so line `i` sits at
/// `i × lineHeight` and its background spans the full width.
final class DiffTextView: NSTextView {
    var lineHeight: CGFloat = 20
    var backgrounds: [NSColor?] = [] {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let top = textContainerOrigin.y
        let first = max(0, Int((rect.minY - top) / lineHeight))
        let last = min(backgrounds.count - 1, Int((rect.maxY - top) / lineHeight))
        guard first <= last else { return }
        for index in first...last {
            guard let color = backgrounds[index] else { continue }
            color.setFill()
            NSRect(x: rect.minX, y: top + CGFloat(index) * lineHeight, width: rect.width, height: lineHeight)
                .fill(using: .sourceOver)
        }
    }
}

/// Old and new line numbers in two right-aligned columns, each at least 34 wide with 10 padding (UX §6.3).
final class DiffGutterView: NSView {
    weak var textView: DiffTextView?
    var lines: [DiffLine] = [] {
        didSet { needsDisplay = true }
    }
    var font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    var lineHeight: CGFloat = 20
    var numberColor = NSColor.secondaryLabelColor
    var background = NSColor.textBackgroundColor

    override var isFlipped: Bool { true }

    private var columnWidth: CGFloat {
        let largest = lines.reduce(0) { max($0, $1.old ?? 0, $1.new ?? 0) }
        let advance = ("8" as NSString).size(withAttributes: [.font: font]).width
        return max(34, CGFloat(String(max(largest, 1)).count) * advance + 10)
    }

    var preferredWidth: CGFloat { columnWidth * 2 }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
        guard let textView else { return }
        let visible = textView.visibleRect
        let top = textView.textContainerOrigin.y - visible.minY
        let column = columnWidth
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: numberColor]
        let first = max(0, Int(visible.minY / lineHeight) - 1)
        let last = min(lines.count - 1, Int(visible.maxY / lineHeight) + 1)
        guard first <= last else { return }
        for index in first...last {
            let y = top + CGFloat(index) * lineHeight
            for (number, right) in [(lines[index].old, column - 10), (lines[index].new, column * 2 - 10)] {
                guard let number else { continue }
                let label = String(number) as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(x: right - size.width, y: y + (lineHeight - size.height) / 2),
                    withAttributes: attributes)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
