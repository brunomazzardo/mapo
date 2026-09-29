import AppKit

/// One split node of a workspace's layout (UX §4.2): lays its children out from ratios along its axis with
/// 8 pt gutters. Each gutter is a divider element, `pane.divider:<splitId>/<index>`. Dragging a gutter
/// resizes live and reports the new ratios once, on mouse-up; a double-click equalizes the split.
/// Geometry never animates.
final class SplitContainerView: NSView {
    static let gutter: CGFloat = 8
    /// The smallest pane a drag may leave (UX §2.2).
    static let minimumPane = NSSize(width: 200, height: 120)

    let splitId: String
    /// `row` lays children left to right, `column` top to bottom.
    private(set) var axis: String
    private(set) var ratios: [Double]
    private(set) var arranged: [NSView] = []
    private var dividers: [SplitDividerView] = []

    /// Mouse-up after a drag: the split and its new ratios.
    var onResize: ((String, [Double]) -> Void)?
    /// Double-click on a gutter.
    var onEqualize: ((String) -> Void)?

    init(splitId: String) {
        self.splitId = splitId
        self.axis = "row"
        self.ratios = []
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SplitContainerView is built in code")
    }

    override var isFlipped: Bool { true }

    private var isRow: Bool { axis != "column" }

    /// Sets the axis, ratios and child views. Children that stay keep their place in the view tree, so
    /// terminals don't leave the window.
    func update(axis: String, ratios: [Double], children: [NSView]) {
        let changed =
            axis != self.axis || ratios != self.ratios
            || children.map(ObjectIdentifier.init)
                != arranged.map(ObjectIdentifier.init)
        guard changed else { return }
        self.axis = axis
        self.ratios =
            ratios.count == children.count
            ? ratios : Array(repeating: 1 / Double(children.count), count: children.count)
        for view in arranged where !children.contains(where: { $0 === view }) && view.superview === self {
            view.removeFromSuperview()
        }
        for view in children where view.superview !== self {
            addSubview(view)
        }
        arranged = children
        let dividerCount = max(children.count - 1, 0)
        while dividers.count > dividerCount { dividers.removeLast().removeFromSuperview() }
        while dividers.count < dividerCount {
            let divider = SplitDividerView(index: dividers.count, owner: self)
            dividers.append(divider)
            addSubview(divider)
        }
        for divider in dividers {
            divider.isVertical = isRow
            divider.setAccessibilityIdentifier(AXID.paneDivider(splitId: splitId, index: divider.index))
            divider.setAccessibilityLabel(isRow ? "Vertical Pane Divider" : "Horizontal Pane Divider")
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let frames = childFrames(for: ratios)
        for (view, frame) in zip(arranged, frames) where view.frame != frame {
            view.frame = frame
        }
        for (divider, frame) in zip(dividers, dividerFrames(for: frames)) {
            divider.frame = frame
        }
    }

    /// Child frames: the length minus the gutters, shared out by ratio, with whole points.
    private func childFrames(for ratios: [Double]) -> [NSRect] {
        let count = arranged.count
        guard count > 0 else { return [] }
        let length = isRow ? bounds.width : bounds.height
        let usable = max(length - Self.gutter * CGFloat(count - 1), 0)
        var frames: [NSRect] = []
        var offset: CGFloat = 0
        for (index, ratio) in ratios.enumerated() {
            let end = index == count - 1 ? usable : (offset + usable * CGFloat(ratio)).rounded()
            let size = max(end - offset, 0)
            let start = offset + CGFloat(index) * Self.gutter
            frames.append(
                isRow
                    ? NSRect(x: start, y: 0, width: size, height: bounds.height)
                    : NSRect(x: 0, y: start, width: bounds.width, height: size))
            offset = end
        }
        return frames
    }

    private func dividerFrames(for frames: [NSRect]) -> [NSRect] {
        zip(frames, frames.dropFirst()).map { first, _ in
            isRow
                ? NSRect(x: first.maxX, y: 0, width: Self.gutter, height: bounds.height)
                : NSRect(x: 0, y: first.maxY, width: bounds.width, height: Self.gutter)
        }
    }

    // MARK: Dragging

    private var dragStart: (point: CGFloat, ratios: [Double])?

    fileprivate func beginDrag(at point: NSPoint) {
        dragStart = (isRow ? point.x : point.y, ratios)
    }

    /// Moves the gutter after child `index` by the drag, keeping both neighbors at least the minimum size.
    fileprivate func drag(divider index: Int, to point: NSPoint) {
        guard let start = dragStart, index + 1 < ratios.count else { return }
        let length = (isRow ? bounds.width : bounds.height) - Self.gutter * CGFloat(arranged.count - 1)
        guard length > 0 else { return }
        let delta = Double(((isRow ? point.x : point.y) - start.point) / length)
        let pair = start.ratios[index] + start.ratios[index + 1]
        let minimum = Double((isRow ? Self.minimumPane.width : Self.minimumPane.height) / length)
        guard pair > 2 * minimum else { return }
        let first = min(max(start.ratios[index] + delta, minimum), pair - minimum)
        var next = start.ratios
        next[index] = first
        next[index + 1] = pair - first
        ratios = next
        needsLayout = true
    }

    fileprivate func endDrag() {
        guard let start = dragStart else { return }
        dragStart = nil
        if ratios != start.ratios { onResize?(splitId, ratios) }
    }

    fileprivate func equalize() {
        onEqualize?(splitId)
    }
}

/// A gutter between two panes: the resize cursor, drag to resize, double-click to equalize.
private final class SplitDividerView: NSView {
    let index: Int
    var isVertical = true {
        didSet { if isVertical != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private weak var owner: SplitContainerView?

    init(index: Int, owner: SplitContainerView) {
        self.index = index
        self.owner = owner
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SplitDividerView is built in code")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        if event.clickCount == 2 {
            owner.equalize()
            return
        }
        owner.beginDrag(at: owner.convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        owner.drag(divider: index, to: owner.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        owner?.endDrag()
    }
}
