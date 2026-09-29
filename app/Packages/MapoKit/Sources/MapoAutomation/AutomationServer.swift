import AppKit
import MapoClient
import MapoProtocol
import MapoUI

/// Serves the daemon's `ui.*` requests on the main actor (PROTOCOL §6.8, PLAN T0.9). Every handler
/// returns promptly; `ui.wait` polls every 50 ms with `Task.sleep`, so the run loop keeps turning.
public final class AutomationServer {
    private let store: AppStore
    private let metrics: UIMetrics
    private let window: () -> NSWindow?

    public init(store: AppStore, metrics: UIMetrics, window: @escaping () -> NSWindow?) {
        self.store = store
        self.metrics = metrics
        self.window = window
    }

    /// The `MapoClient.requestHandler` entry point.
    public func handle(_ request: DaemonRequest) async -> Result<JSONValue, RPCError> {
        do {
            let params = try Params(request.params)
            let result: JSONValue
            switch request.method {
            case "ui.window": result = try windowInfo(params)
            case "ui.tree": result = try tree(params)
            case "ui.snapshot": result = try snapshot(params)
            case "ui.click": result = try await click(params)
            case "ui.press": result = try await press(params)
            case "ui.focus": result = try await focus(params)
            case "ui.type": result = try type(params)
            case "ui.key": result = try key(params)
            case "ui.wait": result = try await wait(params)
            case "ui.metrics": result = try metricsResult(params)
            default:
                throw RPCError.make(.invalidArgument, "The app doesn't handle \(request.method)")
            }
            return .success(result)
        } catch let error as RPCError {
            return .failure(error)
        } catch {
            return .failure(RPCError.make(.internalError, "\(request.method) failed: \(error)"))
        }
    }

    // MARK: Handlers

    private func windowInfo(_ params: Params) throws -> JSONValue {
        try params.allow([])
        return .object(Self.windowInfo(try mainWindow()))
    }

    private static func windowInfo(_ window: NSWindow) -> [String: JSONValue] {
        [
            "windowNumber": .number(Double(window.windowNumber)),
            "frame": ElementGeometry.screenFrame(of: window).json,
            "scale": .number(Double(window.backingScaleFactor)),
            "title": .string(window.title),
            "occluded": .bool(!window.occlusionState.contains(.visible)),
        ]
    }

    private func tree(_ params: Params) throws -> JSONValue {
        try params.allow(["depth", "root"])
        let window = try mainWindow()
        let depth = try params.int("depth", in: 1...64) ?? 12
        let tree = ElementTreeBuilder(window: window, depth: depth).build()
        guard let rootValue = params["root"] else { return tree.json }
        let target = try UITarget(rootValue)
        return try resolve(target, in: tree).json
    }

    private func snapshot(_ params: Params) throws -> JSONValue {
        try params.allow([])
        let window = try mainWindow()
        let tree = ElementTreeBuilder(window: window).build()
        let focus = tree.all.dropFirst().last { $0.focused }
        var layout = JSONValue.null
        if let workspaceId = store.activeWorkspaceId, let value = store.layouts[workspaceId] {
            layout = (try? JSONValue(encoding: value)) ?? .null
        }
        return .object([
            "window": .object(Self.windowInfo(window)),
            "focus": focus.map { .object($0.reference) } ?? .null,
            "tree": tree.json,
            "model": .object([
                "workspaceId": store.activeWorkspaceId.map(JSONValue.string) ?? .null,
                "layout": layout,
                "rail": .array(RailSnapshot.rows(store)),
            ]),
        ])
    }

    private func click(_ params: Params) async throws -> JSONValue {
        try params.allow(["target", "button", "count", "modifiers"])
        let window = try mainWindow()
        let target = try UITarget(try params.require("target"))
        let button = try params.enumValue("button", EventSynthesizer.MouseButton.self) ?? .left
        let count = try params.int("count", in: 1...3) ?? 1
        let modifiers = try params.modifiers("modifiers")

        let point: NSPoint
        let element: UIElement?
        if case .point(let location) = target {
            point = location
            element = ElementTreeBuilder(window: window).build().deepest(at: location)
        } else {
            let found = try await resolveSoon(target, in: window)
            let frame = scrollIntoView(found, in: window)
            let visible = frame.intersection(NSRect(origin: .zero, size: window.frame.size))
            guard !visible.isEmpty else {
                throw RPCError.make(
                    .conflict, "\(found.name) is outside the window", details: ["frame": frame.json])
            }
            point = NSPoint(x: visible.midX, y: visible.midY)
            element = found
        }
        await EventSynthesizer(window: window).click(at: point, button: button, count: count, modifiers: modifiers)
        return .object(["ok": .bool(true), "element": element?.summary ?? .null])
    }

    private func press(_ params: Params) async throws -> JSONValue {
        try params.allow(["target"])
        let window = try mainWindow()
        let element = try await resolveSoon(try UITarget(try params.require("target")), in: window)
        // While the app is inactive AppKit's press can decline, and a control without a target can't reach
        // the window's chain; then send the control's action as if the window were key.
        var pressed = element.object?.accessibilityPerformPress() ?? false
        if !pressed, NSApp.keyWindow !== window, let control = element.view as? NSControl {
            pressed = ActionRouter(window: window).sendAction(of: control)
        }
        guard pressed else {
            throw RPCError.make(
                .conflict, "\(element.name) has no press action", hint: "Try mapo ui click instead")
        }
        return .object(["ok": .bool(true)])
    }

    private func focus(_ params: Params) async throws -> JSONValue {
        try params.allow(["target"])
        let window = try mainWindow()
        let element = try await resolveSoon(try UITarget(try params.require("target")), in: window)
        window.makeKeyAndOrderFront(nil)
        guard let view = element.view, window.makeFirstResponder(view) else {
            throw RPCError.make(.conflict, "\(element.name) can't take keyboard focus")
        }
        return .object(["ok": .bool(true)])
    }

    private func type(_ params: Params) throws -> JSONValue {
        try params.allow(["text"])
        let window = try mainWindow()
        guard case .string(let text) = try params.require("text") else {
            throw RPCError.make(.invalidArgument, "text must be a string")
        }
        do {
            try EventSynthesizer(window: window).type(text)
        } catch .untypable(let character) {
            throw RPCError.make(
                .invalidArgument,
                "Can't type \"\(character)\": it isn't on the US layout and the focused element takes no text",
                hint: "mapo ui snapshot | jq .focus")
        }
        return .object(["ok": .bool(true)])
    }

    private func key(_ params: Params) throws -> JSONValue {
        try params.allow(["chord", "phase"])
        let window = try mainWindow()
        guard case .string(let text) = try params.require("chord") else {
            throw RPCError.make(.invalidArgument, "chord must be a string such as \"cmd+t\"")
        }
        let chord: KeyChord
        do {
            chord = try KeyChord(parsing: text)
        } catch {
            throw RPCError.make(
                .invalidArgument, "Bad chord \"\(text)\": \(error)",
                hint: "Modifiers cmd, shift, alt, ctrl joined with +, then a key such as t, return or f5")
        }
        let phase = try params.enumValue("phase", EventSynthesizer.KeyPhase.self) ?? .press
        EventSynthesizer(window: window).send(chord, phase: phase)
        return .object(["ok": .bool(true)])
    }

    private enum WaitState: String {
        case exists, gone, focused, enabled
    }

    private func wait(_ params: Params) async throws -> JSONValue {
        try params.allow(["target", "state", "timeoutMs"])
        let target = try UITarget(try params.require("target"))
        let state = try params.enumValue("state", WaitState.self) ?? .exists
        let timeoutMs = try params.int("timeoutMs", in: 0...600_000) ?? 5000
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            let window = try mainWindow()
            let tree = ElementTreeBuilder(window: window).build()
            let match = target.find(in: tree)
            let satisfied: Bool
            switch state {
            case .exists: satisfied = match != nil
            case .gone: satisfied = match == nil
            case .focused: satisfied = match?.focused ?? false
            case .enabled: satisfied = match?.enabled ?? false
            }
            if satisfied { return .object(["element": match?.summary ?? .null]) }
            guard ContinuousClock.now < deadline else {
                let seen = match.map { "found it (focused \($0.focused), enabled \($0.enabled))" } ?? "not found"
                throw RPCError.make(
                    .timeout,
                    "Timed out after \(timeoutMs) ms waiting for \(target) to be \(state.rawValue): \(seen). "
                        + tree.summaryLine,
                    hint: "mapo ui snapshot",
                    details: ["ids": .array(tree.identifiers.prefix(80).map(JSONValue.string))])
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func metricsResult(_ params: Params) throws -> JSONValue {
        try params.allow(["reset"])
        let reset: Bool
        switch params["reset"] {
        case nil, .null: reset = false
        case .bool(let value): reset = value
        default: throw RPCError.make(.invalidArgument, "reset must be a boolean")
        }
        return metrics.json(reset: reset)
    }

    // MARK: Helpers

    private func mainWindow() throws -> NSWindow {
        guard let window = window() else {
            throw RPCError.make(.unavailable, "The app has no main window yet")
        }
        return window
    }

    private func resolve(_ target: UITarget, in tree: UIElement) throws -> UIElement {
        if let element = target.find(in: tree) { return element }
        throw RPCError.make(
            .notFound, "No element matches \(target)", hint: "mapo ui tree | jq '[.. | .id? // empty]'",
            details: ["ids": .array(tree.identifiers.prefix(80).map(JSONValue.string))])
    }

    /// Resolves a target that a just-finished CLI command may still be bringing into view: the daemon's
    /// event reaches the app a moment after the command returns, so `mapo workspace new A; mapo ui click
    /// rail.workspace:A` gets up to a second of grace before `not_found`.
    private func resolveSoon(_ target: UITarget, in window: NSWindow) async throws -> UIElement {
        let deadline = ContinuousClock.now + Self.resolveGrace
        while true {
            let tree = ElementTreeBuilder(window: window).build()
            if let element = target.find(in: tree) { return element }
            if ContinuousClock.now >= deadline { return try resolve(target, in: tree) }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static let resolveGrace = Duration.seconds(1)

    /// Scrolls the element's view into its scroll view, such as a rail row, and returns its fresh frame.
    private func scrollIntoView(_ element: UIElement, in window: NSWindow) -> NSRect {
        guard let view = element.view, let object = element.object, view.enclosingScrollView != nil else {
            return element.frame
        }
        if let row = view as? NSTableRowView, let table = row.superview as? NSTableView {
            let index = table.row(for: row)
            if index >= 0 { table.scrollRowToVisible(index) }
        } else {
            view.scrollToVisible(view.bounds)
        }
        window.layoutIfNeeded()
        return ElementGeometry.windowFrame(ofScreenRect: object.accessibilityFrame(), in: window)
    }
}

// MARK: - Targets

/// A `Target` (PROTOCOL §6.8): an identifier, a label, a role and a label, or a point.
enum UITarget: CustomStringConvertible {
    case match(id: String?, role: String?, label: String?)
    case point(NSPoint)

    init(_ value: JSONValue) throws {
        guard case .object(let members) = value else {
            throw RPCError.make(.invalidArgument, "target must be an object such as {\"id\":\"rail\"}")
        }
        for key in members.keys where !["id", "role", "label", "point"].contains(key) {
            throw RPCError.make(.invalidArgument, "Unknown target field \"\(key)\"")
        }
        if let point = members["point"] {
            guard let x = point["x"]?.doubleValue, let y = point["y"]?.doubleValue else {
                throw RPCError.make(.invalidArgument, "target.point needs numbers x and y")
            }
            self = .point(NSPoint(x: x, y: y))
            return
        }
        let id = members["id"]?.stringValue
        let role = members["role"]?.stringValue
        let label = members["label"]?.stringValue
        guard id != nil || label != nil || role != nil else {
            throw RPCError.make(.invalidArgument, "target needs id, label, role and label, or point")
        }
        self = .match(id: id, role: role, label: label)
    }

    func find(in tree: UIElement) -> UIElement? {
        switch self {
        case .point(let point):
            return tree.deepest(at: point)
        case .match(let id, let role, let label):
            return tree.all.first { element in
                (id == nil || element.id == id) && (role == nil || element.role == role)
                    && (label == nil || element.label == label)
            }
        }
    }

    var description: String {
        switch self {
        case .point(let point): return "point \(Int(point.x)),\(Int(point.y))"
        case .match(let id, let role, let label):
            if let id { return id }
            return [role.map { "role \($0)" }, label.map { "label \"\($0)\"" }].compactMap { $0 }.joined(
                separator: " ")
        }
    }
}

extension UIElement {
    /// The deepest element whose frame contains the point; later siblings win, as they draw on top.
    func deepest(at point: NSPoint) -> UIElement? {
        guard frame.contains(point) else { return nil }
        for child in children.reversed() {
            if let hit = child.deepest(at: point) { return hit }
        }
        return self
    }

    var identifiers: [String] {
        all.compactMap(\.id)
    }

    /// How errors name the element.
    var name: String {
        id ?? label.map { "\(role) \"\($0)\"" } ?? role
    }

    /// A one-line summary of the tree for timeout messages.
    var summaryLine: String {
        let elements = all
        let focus = elements.dropFirst().last { $0.focused }.map(\.name) ?? "nothing"
        let ids = identifiers.prefix(20).joined(separator: ", ")
        return "Last tree: \(elements.count) elements, focus on \(focus); ids: \(ids)"
    }
}

// MARK: - Params

/// A request's params object, with the checks of PROTOCOL §4: unknown fields are rejected.
private struct Params {
    let members: [String: JSONValue]

    init(_ value: JSONValue) throws {
        switch value {
        case .object(let members): self.members = members
        case .null: self.members = [:]
        default: throw RPCError.make(.invalidArgument, "params must be an object")
        }
    }

    subscript(key: String) -> JSONValue? {
        members[key]
    }

    func allow(_ keys: Set<String>) throws {
        for key in members.keys.sorted() where !keys.contains(key) {
            throw RPCError.make(.invalidArgument, "Unknown param \"\(key)\"")
        }
    }

    func require(_ key: String) throws -> JSONValue {
        guard let value = members[key], value != .null else {
            throw RPCError.make(.invalidArgument, "Missing param \"\(key)\"")
        }
        return value
    }

    func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = members[key], value != .null else { return nil }
        guard let int = value.intValue, range.contains(int) else {
            throw RPCError.make(
                .invalidArgument, "\(key) must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return int
    }

    func enumValue<Value: RawRepresentable>(_ key: String, _: Value.Type) throws -> Value?
    where Value.RawValue == String {
        guard let value = members[key], value != .null else { return nil }
        guard let raw = value.stringValue, let parsed = Value(rawValue: raw) else {
            throw RPCError.make(.invalidArgument, "Bad \(key) \(value)")
        }
        return parsed
    }

    func modifiers(_ key: String) throws -> KeyModifiers {
        guard let value = members[key], value != .null else { return [] }
        guard case .array(let names) = value else {
            throw RPCError.make(.invalidArgument, "\(key) must be an array such as [\"cmd\"]")
        }
        var modifiers: KeyModifiers = []
        for name in names {
            guard let text = name.stringValue, let modifier = KeyModifiers(name: text) else {
                throw RPCError.make(.invalidArgument, "Unknown modifier \(name) (use cmd, shift, alt or ctrl)")
            }
            modifiers.insert(modifier)
        }
        return modifiers
    }
}

extension RPCError {
    /// An error of `kind` with its PROTOCOL §4 code and `details`.
    static func make(
        _ kind: RPCErrorKind, _ message: String, hint: String? = nil, details: [String: JSONValue] = [:]
    ) -> RPCError {
        var error = RPCError(kind: kind, message: message, hint: hint)
        error.data?.details = .object(details)
        return error
    }
}

extension JSONValue {
    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Any `Encodable` as a `JSONValue`, through `JSONEncoder`.
    init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
