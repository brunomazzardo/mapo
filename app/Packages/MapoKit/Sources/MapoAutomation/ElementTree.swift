import AppKit
import MapoProtocol

/// One `Element` of `ui.tree` (PROTOCOL §7), holding the AppKit object behind it so `ui.click`, `ui.press`
/// and `ui.focus` can act on it.
final class UIElement {
    let object: (any NSAccessibilityProtocol)?
    let id: String?
    let role: String
    let label: String?
    let value: String?
    /// Window points, top-left origin.
    let frame: NSRect
    let focused: Bool
    let enabled: Bool
    let children: [UIElement]

    init(
        object: (any NSAccessibilityProtocol)?, id: String?, role: String, label: String?, value: String?,
        frame: NSRect, focused: Bool, enabled: Bool, children: [UIElement]
    ) {
        self.object = object
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.focused = focused
        self.enabled = enabled
        self.children = children
    }

    /// The view behind the element: the view itself, or a cell's control view.
    var view: NSView? {
        if let view = object as? NSView { return view }
        if let cell = object as? NSCell { return cell.controlView }
        return nil
    }

    /// This element and its descendants, depth first, in display order.
    var all: [UIElement] {
        [self] + children.flatMap(\.all)
    }

    var json: JSONValue {
        var members = reference
        if let value { members["value"] = .string(value) }
        members["focused"] = .bool(focused)
        members["enabled"] = .bool(enabled)
        members["children"] = .array(children.map(\.json))
        return .object(members)
    }

    /// The element without its children.
    var summary: JSONValue {
        var members = reference
        if let value { members["value"] = .string(value) }
        members["focused"] = .bool(focused)
        members["enabled"] = .bool(enabled)
        return .object(members)
    }

    /// An `ElementRef`: `{id, role, label?, frame}`.
    var reference: [String: JSONValue] {
        var members: [String: JSONValue] = [
            "id": id.map(JSONValue.string) ?? .null, "role": .string(role), "frame": frame.json,
        ]
        if let label { members["label"] = .string(label) }
        return members
    }
}

extension NSRect {
    var json: JSONValue {
        .object([
            "x": .number(Self.round(origin.x)), "y": .number(Self.round(origin.y)),
            "w": .number(Self.round(size.width)), "h": .number(Self.round(size.height)),
        ])
    }

    /// Two decimals are enough for points and keep the JSON readable.
    private static func round(_ value: CGFloat) -> Double {
        (Double(value) * 100).rounded() / 100
    }
}

/// Builds the element tree of the main window (PLAN T0.9 step 2): from `window.contentView`, walks
/// `accessibilityChildren()` to `depth` element levels, passing through ignored elements to their children,
/// and adds the toolbar items' views. The root is the window itself, `window.main`.
struct ElementTreeBuilder {
    let window: NSWindow
    let depth: Int
    /// A bound on the whole walk, in case a view vends a cycle.
    private static let maximumElements = 5000

    init(window: NSWindow, depth: Int = 12) {
        self.window = window
        self.depth = depth
    }

    func build() -> UIElement {
        var walk = Walk(window: window)
        var children: [UIElement] = []
        if let content = window.contentView {
            children += walk.elements(of: content, depth: depth - 1)
        }
        for item in window.toolbar?.items ?? [] {
            guard let view = item.view else { continue }
            children += walk.elements(of: view, depth: depth - 1)
        }
        let identifier = window.accessibilityIdentifier()
        return UIElement(
            object: window, id: identifier.isEmpty ? nil : identifier, role: "window",
            label: window.title.isEmpty ? nil : window.title, value: nil,
            frame: NSRect(origin: .zero, size: window.frame.size), focused: window.isKeyWindow, enabled: true,
            children: depth > 1 ? children : [])
    }

    private struct Walk {
        let window: NSWindow
        let focusedView: NSView?
        var visited = Set<ObjectIdentifier>()
        var count = 0

        init(window: NSWindow) {
            self.window = window
            focusedView = Self.focusedView(in: window)
        }

        /// The first responder as a view; a field editor stands for the field it edits.
        static func focusedView(in window: NSWindow) -> NSView? {
            guard let responder = window.firstResponder else { return nil }
            if let text = responder as? NSTextView, text.isFieldEditor, let field = text.delegate as? NSView {
                return field
            }
            return responder as? NSView
        }

        /// The elements `object` contributes: itself with its children, or, when ignored, its children.
        /// `depth` counts the element levels left, this one included.
        mutating func elements(of object: any NSAccessibilityProtocol, depth: Int) -> [UIElement] {
            guard depth >= 1, count < ElementTreeBuilder.maximumElements else { return [] }
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor || view.alphaValue == 0 {
                return []
            }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = object.accessibilityChildren() ?? []
            guard object.isAccessibilityElement() else {
                return children.compactMap { $0 as? any NSAccessibilityProtocol }.flatMap {
                    elements(of: $0, depth: depth)
                }
            }
            count += 1
            var descendants: [UIElement] = []
            if depth > 1 {
                for child in children {
                    guard let child = child as? any NSAccessibilityProtocol else { continue }
                    descendants += elements(of: child, depth: depth - 1)
                }
            }
            return [element(object, children: descendants)]
        }

        private func element(_ object: any NSAccessibilityProtocol, children: [UIElement]) -> UIElement {
            let identifier = object.accessibilityIdentifier()
            var label = object.accessibilityLabel()
            if label?.isEmpty ?? true { label = object.accessibilityTitle() }
            if label?.isEmpty ?? true { label = nil }
            return UIElement(
                object: object, id: identifier?.isEmpty == false ? identifier : nil,
                role: Self.role(object.accessibilityRole()), label: label,
                value: object.accessibilityValue() as? String,
                frame: ElementGeometry.windowFrame(ofScreenRect: object.accessibilityFrame(), in: window),
                focused: isFocused(object), enabled: isEnabled(object), children: children)
        }

        /// Controls and cells report their own state. Other views say false to `isAccessibilityEnabled` by default,
        /// though nothing disables them, so a visible view counts as enabled.
        private func isEnabled(_ object: any NSAccessibilityProtocol) -> Bool {
            if let control = object as? NSControl { return control.isEnabled }
            if let cell = object as? NSCell { return cell.isEnabled }
            if object is NSView { return true }
            return object.isAccessibilityEnabled()
        }

        private func isFocused(_ object: any NSAccessibilityProtocol) -> Bool {
            if let focusedView {
                if let view = object as? NSView { return view === focusedView }
                if let cell = object as? NSCell { return cell.controlView === focusedView }
            }
            return object.isAccessibilityFocused()
        }

        /// `AXButton` becomes `button` (ENGINEERING §4.2).
        static func role(_ role: NSAccessibility.Role?) -> String {
            guard var name = role?.rawValue, !name.isEmpty else { return "unknown" }
            if name.hasPrefix("AX") { name.removeFirst(2) }
            guard let first = name.first else { return "unknown" }
            return first.lowercased() + name.dropFirst()
        }
    }
}

/// Window coordinates for `ui.*`: points, origin at the window's top left (PROTOCOL §6.8).
enum ElementGeometry {
    static func windowFrame(ofScreenRect rect: NSRect, in window: NSWindow) -> NSRect {
        let local = window.convertFromScreen(rect)
        return NSRect(
            x: local.minX, y: window.frame.height - local.maxY, width: local.width, height: local.height)
    }

    /// A top-left window point as AppKit's bottom-left window coordinates, for `NSEvent.mouseEvent`.
    static func eventLocation(ofWindowPoint point: NSPoint, in window: NSWindow) -> NSPoint {
        NSPoint(x: point.x, y: window.frame.height - point.y)
    }

    /// The window's frame in screen points with a top-left origin on the primary display, as
    /// `screencapture` and CoreGraphics see it.
    static func screenFrame(of window: NSWindow) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        let frame = window.frame
        return NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
