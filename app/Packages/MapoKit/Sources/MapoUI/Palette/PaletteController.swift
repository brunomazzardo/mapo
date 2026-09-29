import AppKit
import MapoClient
import SwiftUI

/// What the palette's rows do; the window controller supplies them.
public struct PaletteActions {
    public var focusTab: (_ tabId: String) -> Void
    /// ⌘Return on a tab: Show to the Right.
    public var showTabToTheRight: (_ tabId: String) -> Void
    public var activateWorkspace: (_ workspaceId: String) -> Void
    public var openFile: (_ path: String) -> Void
    public var perform: (_ command: Command) -> Void
    /// Whether a command applies now; the palette lists only those.
    public var isEnabled: (_ command: Command) -> Bool

    public init(
        focusTab: @escaping (String) -> Void, showTabToTheRight: @escaping (String) -> Void,
        activateWorkspace: @escaping (String) -> Void, openFile: @escaping (String) -> Void,
        perform: @escaping (Command) -> Void, isEnabled: @escaping (Command) -> Bool
    ) {
        self.focusTab = focusTab
        self.showTabToTheRight = showTabToTheRight
        self.activateWorkspace = activateWorkspace
        self.openFile = openFile
        self.perform = perform
        self.isEnabled = isEnabled
    }
}

/// The ⌘K palette (UX §10, PLAN T1.7): a borderless panel, a child window of the main window centered over
/// the panes area. Esc, a second ⌘K, a click outside or the panel resigning key closes it, and the main
/// window's first responder is what it was.
public final class PaletteController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let model: PaletteModel
    private let actions: PaletteActions
    private let panel = PalettePanel()
    private let field = PaletteTextField()
    private weak var parent: NSWindow?
    private weak var area: NSView?
    private weak var previousResponder: NSResponder?

    public private(set) var isOpen = false

    public init(store: AppStore, actions: PaletteActions) {
        self.actions = actions
        self.model = PaletteModel(store: store) {
            CommandTable.all.filter { $0.inPalette && $0.milestone == nil && actions.isEnabled($0) }
        }
        super.init()
        field.delegate = self
        panel.delegate = self
        panel.onCommandReturn = { [weak self] in self?.runSelected(alternate: true) }
        // Built once and reused, so opening only resets the query and moves the panel (`palette.open`).
        let hosting = PaletteHostingView(
            rootView: PaletteView(model: model, field: field) { [weak self] index in
                self?.run(index, alternate: false)
            })
        hosting.model = model
        hosting.field = field
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    /// ⌘K: opens over `area` (the panes area) of `window`, or closes.
    public func toggle(in window: NSWindow, over area: NSView?) {
        if isOpen {
            close()
        } else {
            open(in: window, over: area)
        }
    }

    public func open(in window: NSWindow, over area: NSView?) {
        guard !isOpen else { return }
        isOpen = true
        parent = window
        self.area = area
        previousResponder = window.firstResponder
        field.stringValue = ""
        model.update(query: "")
        place()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Closes the palette and gives the main window back its first responder.
    public func close() {
        guard isOpen else { return }
        isOpen = false
        let wasKey = panel.isKeyWindow
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        guard let parent else { return }
        if wasKey { parent.makeKey() }
        if let previousResponder, parent.firstResponder !== previousResponder {
            parent.makeFirstResponder(previousResponder)
        }
    }

    // MARK: Running rows

    private func runSelected(alternate: Bool) {
        run(model.selection, alternate: alternate)
    }

    private func run(_ index: Int, alternate: Bool) {
        guard model.rows.indices.contains(index) else {
            NSSound.beep()
            return
        }
        let row = model.rows[index]
        close()
        switch row.target {
        case .tab(let id):
            if alternate { actions.showTabToTheRight(id) } else { actions.focusTab(id) }
        case .workspace(let id): actions.activateWorkspace(id)
        case .file(let path): actions.openFile(path)
        case .command(let command): actions.perform(command)
        }
    }

    // MARK: Layout

    /// 600 wide, clamped between 420 and the panes area's width minus 48, centered over the panes area, its
    /// top 8 pt below the toolbar band; as tall as the content, up to 480 (UX §10).
    private func place() {
        guard let parent else { return }
        let height = PaletteView.height(groups: model.groups.count, rows: model.rows.count, query: model.query)
        let areaFrame: NSRect
        if let area, area.window === parent {
            areaFrame = parent.convertToScreen(area.convert(area.bounds, to: nil))
        } else {
            areaFrame = parent.frame
        }
        let width = max(420, min(600, areaFrame.width - 48))
        let toolbarBand = parent.frame.height - parent.contentLayoutRect.height
        let top = parent.frame.maxY - toolbarBand - 8
        let frame = NSRect(x: (areaFrame.midX - width / 2).rounded(), y: top - height, width: width, height: height)
        panel.setFrame(frame, display: isOpen)
    }

    // MARK: NSTextFieldDelegate

    public func controlTextDidChange(_ notification: Notification) {
        model.update(query: field.stringValue)
        place()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            model.move(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            model.move(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            runSelected(alternate: false)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// The palette's window: borderless, able to take key, transparent around the rounded content.
final class PalettePanel: NSPanel {
    /// ⌘Return runs the selected row's alternate (Show to the Right for a tab).
    var onCommandReturn: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        title = "Go to Tab, File or Command"
        setAccessibilityIdentifier(AXID.palette)
        setAccessibilityLabel(title)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        let returnKeys: Set<UInt16> = [36, 76]
        if event.type == .keyDown, returnKeys.contains(event.keyCode),
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        {
            onCommandReturn?()
            return
        }
        super.sendEvent(event)
    }
}

/// `palette.field`: 15 pt text, no border or focus ring, and the placeholder of UX §10.
final class PaletteTextField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 15)
        textColor = Tokens.textPrimary
        placeholderString = "Go to tab, file or command"
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        setAXIdentifier(AXID.paletteField)
        setAccessibilityLabel("Go to tab, file or command")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaletteTextField is built in code")
    }
}

/// SwiftUI builds its accessibility tree only for assistive apps, so in process the hosting view has no
/// accessibility children and `ui.tree` couldn't see the field or rows. This view lists them itself: the
/// AppKit field, then one element per row (`palette.row:<i>`) laid out like `PaletteView`.
final class PaletteHostingView<Content: View>: NSHostingView<Content> {
    weak var model: PaletteModel?
    weak var field: NSTextField?

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        if let field { children.append(field) }
        guard let model else { return children }
        if model.rows.isEmpty && !model.query.isEmpty {
            let empty = NSAccessibilityElement()
            empty.setAccessibilityRole(.staticText)
            empty.setAccessibilityLabel("No matches for \"\(model.query)\"")
            empty.setAccessibilityParent(self)
            children.append(empty)
        }
        var y = PaletteView.fieldHeight + 1 + PaletteView.listPadding
        var section: PaletteSection?
        for row in model.rows {
            if row.section != section {
                section = row.section
                y += PaletteView.headerHeight
            }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.row)
            element.setAccessibilityIdentifier(AXID.paletteRow(row.id))
            element.setAccessibilityLabel(row.accessibilityLabel)
            element.setAccessibilityValue(row.id == model.selection ? "selected" : nil)
            element.setAccessibilityParent(self)
            let top = isFlipped ? y : bounds.height - y - PaletteView.rowHeight
            let rect = NSRect(x: 0, y: top, width: bounds.width, height: PaletteView.rowHeight)
            element.setAccessibilityFrameInParentSpace(rect)
            children.append(element)
            y += PaletteView.rowHeight
        }
        return children
    }
}
