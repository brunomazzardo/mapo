import AppKit

/// One file's body in the file pane (UX §6, PLAN T1.6): a TextKit 2 editor with its gutter, bars and
/// recovery, or an image or PDF preview, or a binary notice. The view is `pane.file:<absPath>`; its text view
/// is `editor:<absPath>`. `EditorRegistry` keeps one per path, so the buffer outlives a pane and follows the
/// path from one workspace's card to another's.
public final class FileEditorView: NSView, NSTextViewDelegate, CodeTextViewCommands {
    /// The messages of UX §6.2. `rawKind` is the bar's AX value.
    enum Bar: Equatable {
        case none
        case readOnly
        case binary
        case changedOnDisk
        case deleted
        case recovered
        case saveFailed(String)
        case openFailed(String)

        var rawKind: String {
            switch self {
            case .none: "none"
            case .readOnly: "readOnly"
            case .binary: "binary"
            case .changedOnDisk: "changedOnDisk"
            case .deleted: "deleted"
            case .recovered: "recovered"
            case .saveFailed: "saveFailed"
            case .openFailed: "openFailed"
            }
        }
    }

    public let path: String
    public private(set) var isDirty = false
    public private(set) var kind: FileKind = .text
    /// The header meta for previews ("1280 × 800 · 214 KB", "12 pages"); nil for text.
    public private(set) var headerMeta: String?
    public private(set) var softWrap = false
    public private(set) var showsLineNumbers = true

    /// The card's listener: dirty state or header meta changed.
    public var onStateChange: (() -> Void)?
    /// [Close] on the "deleted on disk" bar.
    public var onCloseRequest: (() -> Void)?
    /// The registry's listener.
    var onDirtyChange: ((FileEditorView) -> Void)?
    /// Reads the file's text at HEAD (`git.baseText`); nil when HEAD doesn't have it.
    var baseTextLoader: ((String) async -> String?)?
    /// The git gutter's marks against HEAD (R-ED-3).
    public private(set) var gitMarks = GitGutterMarks()

    private var document: FileDocument
    private let theme: EditorTheme
    private let recovery: RecoveryStore?
    private let undo = UndoManager()
    private var watcher: FileWatcher?
    private var bar = Bar.none
    private var savedText = ""
    private var lines = LineIndex()
    private var highlighter: (any SyntaxHighlighter)?
    private var generation = 0
    private var highlightWork: DispatchWorkItem?
    private var recoveryTimer: Timer?
    private var lastRecoveryGeneration = -1
    private var baseText: String?
    private var gutterWork: Task<Void, Never>?

    private let barView = EditorBarView()
    private let goToLineBar = GoToLineBar()
    private var showsGoToLine = false
    private var scrollView: NSScrollView?
    private var textView: CodeTextView?
    private var gutter: LineNumberGutter?
    private var currentLine: CurrentLineView?
    private var preview: (any FilePreview)?

    /// Reads the file now. `recoveryDirectory` holds recovery copies; nil turns recovery off.
    init(path: String, theme: EditorTheme, recoveryDirectory: URL?) {
        self.path = path
        self.theme = theme
        document = FileDocument(path: path)
        recovery = recoveryDirectory.map { RecoveryStore(directory: $0) }
        highlighter = SyntaxLanguage(path: path)?.highlighter
        super.init(frame: .zero)
        wantsLayer = true
        barView.theme = theme
        goToLineBar.theme = theme
        barView.isHidden = true
        goToLineBar.isHidden = true
        goToLineBar.onGo = { [weak self] line, column in
            self?.goToLine(line, column: column)
            self?.hideGoToLine()
        }
        goToLineBar.onCancel = { [weak self] in self?.hideGoToLine() }
        goToLineBar.field.setAccessibilityIdentifier(EditorAXID.goToLine(path))
        addSubview(barView)
        addSubview(goToLineBar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(EditorAXID.body(path))
        setAccessibilityLabel(document.name)
        load()
        watcher = FileWatcher(
            path: path, onChange: { [weak self] in self?.diskChanged() },
            onDelete: { [weak self] in self?.diskDeleted() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FileEditorView is built in code")
    }

    public override var isFlipped: Bool { true }

    public var name: String { document.name }

    /// Stops watching and autosaving. The registry calls it when it drops a clean editor.
    func close() {
        watcher?.stop()
        watcher = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        highlightWork?.cancel()
        gutterWork?.cancel()
    }

    // MARK: Git gutter (R-ED-3, UX §6.1)

    /// Fetches HEAD's text again (after a commit or a branch switch) and redraws the gutter.
    public func refreshBaseText() {
        guard let baseTextLoader else { return }
        let path = path
        Task { [weak self] in
            let base = await baseTextLoader(path)
            guard let self else { return }
            baseText = base
            updateGitMarks()
        }
    }

    /// Diffs the buffer against the base 200 ms after typing stops.
    private func scheduleGitMarks() {
        gutterWork?.cancel()
        gutterWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.updateGitMarks()
        }
    }

    private func updateGitMarks() {
        let marks: GitGutterMarks
        if let textView, kind == .text || kind == .largeText {
            // Without a base in HEAD, a file in a repository is all new; outside one there are no marks.
            marks = baseText.map { GitGutterMarks(base: $0, text: textView.string) } ?? GitGutterMarks()
        } else {
            marks = GitGutterMarks()
        }
        gitMarks = marks
        gutter?.marks = marks
        gutter?.setAccessibilityValue(marks.summary)
    }

    // MARK: Loading

    private func load() {
        let text: String?
        do {
            text = try document.load()
        } catch {
            show(.openFailed(error.localizedDescription))
            return
        }
        kind = document.kind
        switch kind {
        case .text, .largeText:
            buildTextView()
            setText(text ?? "", highlightNow: true)
            if kind == .largeText {
                textView?.isEditable = false
                show(.readOnly)
            }
            offerRecovery()
        case .binary:
            show(.binary)
        case .image:
            install(preview: ImagePreviewView(path: path, data: document.diskData, theme: theme))
        case .pdf:
            install(preview: PDFPreviewView(path: path, data: document.diskData))
        }
    }

    private func install(preview new: any FilePreview) {
        preview?.removeFromSuperview()
        preview = new
        addSubview(new, positioned: .below, relativeTo: barView)
        headerMeta = new.meta
        needsLayout = true
        onStateChange?()
    }

    private func buildTextView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.background
        scroll.findBarPosition = .aboveContent
        scroll.contentView.postsBoundsChangedNotifications = true

        let text = CodeTextView(usingTextLayoutManager: true)
        text.theme = theme
        text.commands = self
        text.delegate = self
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.smartInsertDeleteEnabled = false
        text.usesFontPanel = false
        text.drawsBackground = false
        text.font = theme.font
        text.defaultParagraphStyle = theme.paragraphStyle
        text.typingAttributes = theme.textAttributes
        text.insertionPointColor = theme.text
        text.textContainerInset = NSSize(width: 8, height: 10)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.updateSelectionColor(active: false)
        text.setAccessibilityIdentifier(EditorAXID.editor(path))
        text.setAccessibilityLabel(document.name)
        text.onFocusChange = { [weak self] in self?.updateCurrentLine() }
        scroll.documentView = text

        let band = CurrentLineView()
        scroll.contentView.addSubview(band, positioned: .below, relativeTo: text)

        let gutter = LineNumberGutter()
        gutter.textView = text
        gutter.theme = theme
        gutter.marks = gitMarks
        gutter.setAccessibilityElement(true)
        gutter.setAccessibilityRole(.group)
        gutter.setAccessibilityIdentifier(EditorAXID.gutter(path))
        gutter.setAccessibilityLabel("Changes Against HEAD")
        gutter.setAccessibilityValue(gitMarks.summary)

        addSubview(gutter, positioned: .below, relativeTo: barView)
        addSubview(scroll, positioned: .below, relativeTo: barView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scrollView = scroll
        textView = text
        self.gutter = gutter
        currentLine = band
        applyWrap()
    }

    /// Replaces the buffer with `text` as the saved state: attributes, line index, highlighting, undo.
    private func setText(_ text: String, highlightNow: Bool) {
        guard let textView, let storage = textView.textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: text, attributes: theme.textAttributes))
        savedText = text
        undo.removeAllActions()
        textChanged(highlightNow: highlightNow)
        setDirty(false)
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        var top: CGFloat = 0
        if !barView.isHidden {
            barView.frame = NSRect(x: 0, y: top, width: bounds.width, height: EditorBarView.height)
            top += EditorBarView.height
        }
        if !goToLineBar.isHidden {
            goToLineBar.frame = NSRect(x: 0, y: top, width: bounds.width, height: EditorBarView.height)
            top += EditorBarView.height
        }
        let body = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        preview?.frame = body
        guard let scrollView, let gutter else { return }
        let gutterWidth = showsLineNumbers ? gutter.preferredWidth : 0
        gutter.isHidden = !showsLineNumbers
        gutter.frame = NSRect(x: body.minX, y: body.minY, width: gutterWidth, height: body.height)
        scrollView.frame = NSRect(
            x: body.minX + gutterWidth, y: body.minY, width: max(0, body.width - gutterWidth), height: body.height)
        // Without line numbers the text keeps a 12 pt margin from the card edge.
        let left: CGFloat = showsLineNumbers ? 8 : 12
        if textView?.textContainerInset.width != left {
            textView?.textContainerInset = NSSize(width: left, height: 10)
        }
        gutter.textInset = left
        updateCurrentLine()
        gutter.needsDisplay = true
    }

    @objc private func scrolled() {
        gutter?.needsDisplay = true
    }

    // MARK: Focus

    /// Gives keyboard focus to the text, the preview, or the bar's first button.
    public func focus() {
        guard let window else { return }
        if let textView {
            window.makeFirstResponder(textView)
        } else if let preview {
            window.makeFirstResponder(preview.focusView)
        } else if let button = barView.firstButton {
            window.makeFirstResponder(button)
        }
    }

    // MARK: Editing

    public func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        view.isEditable
    }

    public func undoManager(for view: NSTextView) -> UndoManager? {
        undo
    }

    public func textDidChange(_ notification: Notification) {
        textChanged(highlightNow: false)
        setDirty((textView?.string ?? "") != savedText)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        updateCurrentLine()
        gutter?.needsDisplay = true
    }

    private func textChanged(highlightNow: Bool) {
        guard let textView else { return }
        generation += 1
        let text = textView.string as NSString
        lines.rebuild(text)
        gutter?.lines = lines
        textView.indent = Self.detectIndent(text)
        if let gutter, abs(gutter.frame.width - gutter.preferredWidth) > 0.5, showsLineNumbers {
            needsLayout = true
        }
        gutter?.needsDisplay = true
        updateCurrentLine()
        scheduleHighlight(now: highlightNow)
        scheduleGitMarks()
    }

    private func setDirty(_ dirty: Bool) {
        guard dirty != isDirty else { return }
        isDirty = dirty
        setAccessibilityLabel(dirty ? "\(document.name), edited" : document.name)
        if dirty {
            startRecovery()
        } else {
            recoveryTimer?.invalidate()
            recoveryTimer = nil
            recovery?.remove(path: path)
        }
        onDirtyChange?(self)
        onStateChange?()
    }

    /// The indent Tab inserts: a tab when most indented lines start with one, else the smallest common
    /// run of spaces (2 or 4), 4 by default.
    static func detectIndent(_ text: NSString) -> String {
        var tabs = 0
        var twos = 0
        var fours = 0
        var lineStart = true
        var spaces = 0
        let limit = min(text.length, 64 * 1024)
        for i in 0..<limit {
            let c = text.character(at: i)
            if lineStart {
                if c == 9 {
                    tabs += 1
                    lineStart = false
                } else if c == 32 {
                    spaces += 1
                    continue
                } else {
                    if spaces > 0, c != 10 {
                        if spaces % 4 == 0 { fours += 1 } else if spaces % 2 == 0 { twos += 1 }
                    }
                    lineStart = false
                }
            }
            if c == 10 {
                lineStart = true
                spaces = 0
            }
        }
        if tabs > twos + fours { return "\t" }
        if twos > fours / 2 { return "  " }
        return "    "
    }

    // MARK: Highlighting

    /// On open, the first screenful highlights synchronously so the first frame is colored, and the whole
    /// buffer follows off the main thread; edits highlight off the main thread 150 ms after typing stops.
    /// Read-only large files stay plain.
    private func scheduleHighlight(now: Bool) {
        highlightWork?.cancel()
        guard let highlighter, let textView, kind == .text else { return }
        let text = textView.string
        let current = generation
        if now {
            let head = min((text as NSString).length, lines.start(of: Self.firstScreenLines))
            let prefix = (text as NSString).substring(to: head)
            applyHighlight(highlighter.tokens(in: prefix), in: NSRange(location: 0, length: head), generation: current)
            if head == (text as NSString).length { return }
        }
        let work = DispatchWorkItem { [weak self] in
            Task.detached(priority: .userInitiated) {
                let tokens = highlighter.tokens(in: text)
                await MainActor.run {
                    self?.applyHighlight(
                        tokens, in: NSRange(location: 0, length: (text as NSString).length), generation: current)
                }
            }
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.15), execute: work)
    }

    /// More lines than a tall pane shows.
    private static let firstScreenLines = 150

    private func applyHighlight(_ tokens: [SyntaxToken], in range: NSRange, generation: Int) {
        guard generation == self.generation, let storage = textView?.textStorage,
            NSMaxRange(range) <= storage.length
        else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: theme.text, range: range)
        for token in tokens where NSMaxRange(token.range) <= NSMaxRange(range) {
            if let color = theme.syntax[token.kind] {
                storage.addAttribute(.foregroundColor, value: color, range: token.range)
            }
        }
        storage.endEditing()
    }

    // MARK: Current line

    private func updateCurrentLine() {
        guard let band = currentLine, let textView, let scrollView else { return }
        let selection = textView.selectedRange()
        guard textView.isFocused, selection.length == 0, let rect = lineRect(at: selection.location) else {
            band.isHidden = true
            return
        }
        band.isHidden = false
        band.color = theme.currentLine
        let width = max(textView.frame.width, scrollView.contentView.bounds.width)
        band.frame = NSRect(
            x: 0, y: textView.frame.minY + textView.textContainerOrigin.y + rect.minY, width: width,
            height: rect.height)
    }

    /// The visual line holding `offset`, in text container coordinates.
    private func lineRect(at offset: Int) -> NSRect? {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else {
            return nil
        }
        let length = (textView.string as NSString).length
        let start = content.documentRange.location
        guard let location = content.location(start, offsetBy: min(offset, length)) else { return nil }
        let atEnd = offset >= length
        let fragment =
            layout.textLayoutFragment(for: location)
            ?? (atEnd ? layout.textLayoutFragment(for: content.documentRange.endLocation) : nil)
        guard let fragment else {
            return NSRect(x: 0, y: 0, width: 0, height: theme.lineHeight)
        }
        let frame = fragment.layoutFragmentFrame
        let fragmentStart = content.offset(from: start, to: fragment.rangeInElement.location)
        let local = offset - fragmentStart
        let lineFragments = fragment.textLineFragments
        let line =
            lineFragments.first { NSLocationInRange(local, $0.characterRange) }
            ?? (atEnd || local >= (lineFragments.last?.characterRange.upperBound ?? 0)
                ? lineFragments.last : lineFragments.first)
        guard let line else { return frame }
        let bounds = line.typographicBounds
        return NSRect(x: 0, y: frame.minY + bounds.minY, width: frame.width, height: bounds.height)
    }

    // MARK: Commands

    public func save() {
        guard let textView, kind == .text, textView.isEditable else {
            NSSound.beep()
            return
        }
        let text = textView.string
        do {
            try document.save(text)
        } catch {
            show(.saveFailed(Self.saveFailure(error)))
            return
        }
        savedText = text
        setDirty(false)
        recovery?.remove(path: path)
        watcher?.arm()
        if bar != .none && bar != .readOnly { show(.none) }
    }

    private static func saveFailure(_ error: Error) -> String {
        let code = (error as NSError).code
        if code == NSFileWriteNoPermissionError || code == NSFileWriteVolumeReadOnlyError {
            return "You don't have permission to write to it; check its permissions in Finder, then try again."
        }
        if code == NSFileWriteInapplicableStringEncodingError {
            return "Its text can't be saved in the file's encoding."
        }
        return error.localizedDescription
    }

    func showGoToLine() {
        guard textView != nil else { return NSSound.beep() }
        showsGoToLine = true
        goToLineBar.isHidden = false
        goToLineBar.field.stringValue = ""
        needsLayout = true
        window?.makeFirstResponder(goToLineBar.field)
    }

    private func hideGoToLine() {
        showsGoToLine = false
        goToLineBar.isHidden = true
        needsLayout = true
        focus()
    }

    /// Moves the caret to one-based `line` (and `column`) and centers that line.
    public func goToLine(_ line: Int, column: Int? = nil) {
        guard let textView, let layout = textView.textLayoutManager, let scrollView else { return }
        let text = textView.string as NSString
        let start = lines.start(of: line - 1)
        let end = line < lines.count ? lines.start(of: line) - 1 : text.length
        let offset = min(start + max(0, (column ?? 1) - 1), max(start, end))
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        if let content = layout.textContentManager,
            let target = content.location(content.documentRange.location, offsetBy: offset),
            let range = NSTextRange(location: content.documentRange.location, end: target)
        {
            layout.ensureLayout(for: range)
        }
        if let rect = lineRect(at: offset) {
            let visible = scrollView.contentView.bounds
            let y = textView.textContainerOrigin.y + rect.midY - visible.height / 2
            let maxY = max(0, textView.frame.height - visible.height)
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: min(max(0, y), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        gutter?.needsDisplay = true
        updateCurrentLine()
    }

    public func toggleSoftWrap() {
        softWrap.toggle()
        applyWrap()
    }

    public func toggleLineNumbers() {
        showsLineNumbers.toggle()
        needsLayout = true
    }

    private func applyWrap() {
        guard let textView, let container = textView.textContainer, let scrollView else { return }
        if softWrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            textView.autoresizingMask = [.width]
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
        }
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        gutter?.needsDisplay = true
    }

    // MARK: External changes (R-ED-4)

    private func diskChanged() {
        guard let data = document.readDisk() else { return diskDeleted() }
        if bar == .deleted { show(.none) }
        guard data != document.diskData else { return }
        switch kind {
        case .text:
            if isDirty {
                show(.changedOnDisk)
            } else {
                reload(data)
            }
        case .largeText, .binary, .image, .pdf:
            reloadAll()
        }
    }

    private func diskDeleted() {
        show(.deleted)
    }

    /// Takes the disk's text, keeping the selection and scroll position where they still fit.
    private func reload(_ data: Data) {
        guard let textView, let text = document.decode(data) else { return reloadAll() }
        let selection = textView.selectedRange()
        let origin = scrollView?.contentView.bounds.origin
        document.adopt(data)
        setText(text, highlightNow: true)
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        if let origin, let scrollView {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if bar == .changedOnDisk { show(.none) }
    }

    /// Rebuilds a preview or read-only body from disk.
    private func reloadAll() {
        preview?.removeFromSuperview()
        preview = nil
        scrollView?.removeFromSuperview()
        gutter?.removeFromSuperview()
        scrollView = nil
        textView = nil
        gutter = nil
        currentLine = nil
        show(.none)
        load()
        needsLayout = true
    }

    private func keepMine() {
        if let data = document.readDisk() { document.adopt(data) }
        show(.none)
        focus()
    }

    private func reloadFromDisk() {
        guard let data = document.readDisk() else { return diskDeleted() }
        reload(data)
        show(.none)
        focus()
    }

    // MARK: Recovery (R-ED-5)

    private func startRecovery() {
        guard recovery != nil, recoveryTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeRecovery() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recoveryTimer = timer
    }

    private func writeRecovery() {
        guard isDirty, let recovery, let textView, generation != lastRecoveryGeneration else { return }
        do {
            try recovery.write(path: path, text: textView.string)
            lastRecoveryGeneration = generation
        } catch {
            NSLog("mapo editor: can't write the recovery copy of %@: %@", path, "\(error)")
        }
    }

    /// Offers a recovery copy that is newer than the file and differs from it.
    private func offerRecovery() {
        guard let recovery, let copy = recovery.read(path: path) else { return }
        let fileDate = document.modificationDate ?? .distantPast
        if copy.savedAt > fileDate, copy.text != savedText {
            show(.recovered)
        } else {
            recovery.remove(path: path)
        }
    }

    private func restoreRecovery() {
        guard let recovery, let copy = recovery.read(path: path), let textView, let storage = textView.textStorage
        else { return show(.none) }
        let whole = NSRange(location: 0, length: storage.length)
        if textView.shouldChangeText(in: whole, replacementString: copy.text) {
            storage.replaceCharacters(in: whole, with: copy.text)
            textView.didChangeText()
        }
        show(.none)
        focus()
    }

    private func discardRecovery() {
        recovery?.remove(path: path)
        show(.none)
        focus()
    }

    /// Don't Save when closing the pane: back to the file's text, without a recovery copy.
    public func revertToSaved() {
        abandon()
        if let text = document.decode(document.diskData) { setText(text, highlightNow: true) }
    }

    /// Don't Save at quit: the buffer is abandoned, so its recovery copy goes too.
    func abandon() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recovery?.remove(path: path)
    }

    // MARK: Bars (UX §6.2)

    private func show(_ new: Bar) {
        bar = new
        let name = document.name
        switch new {
        case .none:
            barView.isHidden = true
        case .readOnly:
            barView.show(
                kind: new.rawKind, text: "This file is over 8 MB, so it opened read-only.",
                buttons: [openDefaultButton])
        case .binary:
            barView.show(
                kind: new.rawKind, text: "\(name) is a binary file.", buttons: [openDefaultButton, revealButton])
        case .changedOnDisk:
            barView.show(
                kind: new.rawKind, text: "\(name) changed on disk. Keep your edits, or reload and lose them?",
                buttons: [
                    .init(title: "Keep Mine", identifier: EditorAXID.keepMine(path), isDefault: true) {
                        [weak self] in self?.keepMine()
                    },
                    .init(title: "Reload", identifier: EditorAXID.reload(path)) { [weak self] in
                        self?.reloadFromDisk()
                    },
                ])
        case .deleted:
            barView.show(
                kind: new.rawKind, text: "\(name) was deleted on disk. Save to recreate it, or close the pane.",
                buttons: [
                    .init(title: "Close", identifier: EditorAXID.close(path)) { [weak self] in
                        self?.onCloseRequest?()
                    }
                ])
        case .recovered:
            barView.show(
                kind: new.rawKind, text: "Recovered unsaved edits to \(name) from a previous session.",
                buttons: [
                    .init(title: "Restore", identifier: EditorAXID.restore(path), isDefault: true) {
                        [weak self] in self?.restoreRecovery()
                    },
                    .init(title: "Discard", identifier: EditorAXID.discard(path)) { [weak self] in
                        self?.discardRecovery()
                    },
                ])
        case .saveFailed(let why):
            barView.show(
                kind: new.rawKind, text: "Couldn't save \(name). \(why)",
                buttons: [
                    .init(title: "Try Again", identifier: EditorAXID.retrySave(path), isDefault: true) {
                        [weak self] in self?.save()
                    },
                    revealButton,
                ])
        case .openFailed(let why):
            barView.show(
                kind: new.rawKind, text: "Couldn't open \(name). \(why)", buttons: [revealButton])
        }
        if new != .none {
            barView.setAccessibilityIdentifier(EditorAXID.bar(path))
            barView.isHidden = false
        }
        needsLayout = true
    }

    private var openDefaultButton: EditorBarView.Button {
        .init(title: "Open With Default App", identifier: EditorAXID.openDefault(path)) { [path] in
            NSWorkspace.shared.open(URL(filePath: path))
        }
    }

    private var revealButton: EditorBarView.Button {
        .init(title: "Reveal in Finder", identifier: EditorAXID.reveal(path)) { [path] in
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
        }
    }
}
