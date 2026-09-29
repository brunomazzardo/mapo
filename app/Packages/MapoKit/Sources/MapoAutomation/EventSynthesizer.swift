import AppKit

/// Synthesizes input inside the app's own process, so `ui.*` needs no Accessibility permission
/// (ARCHITECTURE §4.6, PLAN T0.9 step 4).
struct EventSynthesizer {
    let window: NSWindow

    enum MouseButton: String {
        case left, right
    }

    enum KeyPhase: String {
        case press, down, up
    }

    enum TypeError: Error {
        /// The character isn't on the US layout and the first responder can't take inserted text.
        case untypable(Character)
    }

    // MARK: Mouse

    /// Clicks at a top-left window point. Posts the mouse-up to the end of the queue first, then sends the
    /// mouse-down, so a control that runs a tracking loop takes the up from the queue. Later clicks of a
    /// multi-click wait a turn, so the previous up is handled first.
    func click(at point: NSPoint, button: MouseButton, count: Int, modifiers: KeyModifiers) async {
        var target = window
        var location = ElementGeometry.eventLocation(ofWindowPoint: point, in: window)
        // A sheet or child panel (a `dialog`, the palette) over the point is its own window: click it there.
        let screenPoint = window.convertPoint(toScreen: location)
        let overlays = [window.attachedSheet].compactMap { $0 } + (window.childWindows ?? [])
        if let over = overlays.last(where: { $0.isVisible && $0.frame.contains(screenPoint) }) {
            target = over
            location = over.convertPoint(fromScreen: screenPoint)
        }
        let (downType, upType): (NSEvent.EventType, NSEvent.EventType) =
            button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for clickCount in 1...max(1, count) {
            if clickCount > 1 { try? await Task.sleep(for: .milliseconds(10)) }
            guard
                let down = mouseEvent(
                    downType, at: location, in: target, clickCount: clickCount, modifiers: modifiers),
                let up = mouseEvent(upType, at: location, in: target, clickCount: clickCount, modifiers: modifiers)
            else { continue }
            NSApp.postEvent(up, atStart: false)
            target.sendEvent(down)
        }
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at location: NSPoint, in target: NSWindow? = nil, clickCount: Int,
        modifiers: KeyModifiers
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: modifiers.flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (target ?? window).windowNumber,
            context: nil,
            eventNumber: Self.nextEventNumber(), clickCount: clickCount,
            pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)
    }

    // MARK: Keys

    /// Sends a chord like a person: the key-down goes to the main menu's key equivalents first, then to the
    /// window; the key-up goes to the window. A modifiers-only chord sends `flagsChanged`.
    func send(_ chord: KeyChord, phase: KeyPhase) {
        guard let key = chord.key else {
            sendFlags(chord.modifiers, phase: phase)
            return
        }
        if phase != .up, Self.isQuit(chord) {
            // Quitting may put up the unsaved-files sheet, whose modal loop would block this handler and
            // every later ui.* call. Answer first, then quit on the next run loop turn.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            return
        }
        if phase != .up, let down = keyEvent(.keyDown, key: key, modifiers: chord.modifiers) {
            let handled: Bool
            if NSApp.keyWindow === window {
                handled = NSApp.mainMenu?.performKeyEquivalent(with: down) ?? false
            } else {
                handled = NSApp.mainMenu.map { performMenuItem(in: $0, key: key, modifiers: chord.modifiers) } ?? false
            }
            if !handled { window.sendEvent(down) }
        }
        if phase != .down, let up = keyEvent(.keyUp, key: key, modifiers: chord.modifiers) {
            window.sendEvent(up)
        }
    }

    private static func isQuit(_ chord: KeyChord) -> Bool {
        chord.modifiers.flags.intersection([.command, .shift, .option, .control]) == .command
            && chord.key.map { USKeyboard.charactersIgnoringModifiers(of: $0, modifiers: chord.modifiers) } == "q"
    }

    /// While the app is inactive, which is the usual state while an agent drives it from a terminal, the
    /// window isn't key and AppKit's menus can't reach the window's responder chain: `performKeyEquivalent`
    /// declines, or matches an item and sends its action nowhere. So then find the enabled item with this
    /// key equivalent and send its action through the window's chain, as the menu would with the window key.
    private func performMenuItem(in menu: NSMenu, key: USKey, modifiers: KeyModifiers) -> Bool {
        let wanted = modifiers.flags.intersection([.command, .shift, .option, .control])
        guard !wanted.isDisjoint(with: [.command, .control]) else { return false }
        for item in menu.items {
            if let submenu = item.submenu {
                if performMenuItem(in: submenu, key: key, modifiers: modifiers) { return true }
                continue
            }
            guard let action = item.action, !item.keyEquivalent.isEmpty else { continue }
            var itemFlags = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            // An uppercase key equivalent implies shift, and so does a shifted symbol such as "}" for ⇧⌘].
            let equivalent = item.keyEquivalent
            if equivalent != equivalent.lowercased() || USKeyboard.isShiftedSymbol(equivalent) {
                itemFlags.insert(.shift)
            }
            let typed = USKeyboard.charactersIgnoringModifiers(of: key, modifiers: modifiers)
            guard itemFlags == wanted, equivalent.lowercased() == typed.lowercased() else {
                continue
            }
            let router = ActionRouter(window: window)
            guard let target = item.target ?? router.target(for: action), router.isEnabled(item, target: target) else {
                return false
            }
            return NSApp.sendAction(action, to: target, from: item)
        }
        return false
    }

    /// Types `text` into the first responder: a key-down and key-up per character with its US key code and
    /// shift. Characters outside the table go through `insertText` of an `NSTextInputClient` responder.
    func type(_ text: String) throws(TypeError) {
        for character in text {
            if let key = USKeyboard.key(for: character) {
                let modifiers: KeyModifiers = key.shift ? .shift : []
                if let down = keyEvent(.keyDown, key: key, modifiers: modifiers) { window.sendEvent(down) }
                if let up = keyEvent(.keyUp, key: key, modifiers: modifiers) { window.sendEvent(up) }
            } else if let client = window.firstResponder as? NSTextInputClient {
                client.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                throw .untypable(character)
            }
        }
    }

    private func keyEvent(_ type: NSEvent.EventType, key: USKey, modifiers: KeyModifiers) -> NSEvent? {
        var flags = modifiers.flags
        if key.function { flags.insert(.function) }
        if key.numericPad { flags.insert(.numericPad) }
        return NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: USKeyboard.characters(of: key, modifiers: modifiers),
            charactersIgnoringModifiers: USKeyboard.charactersIgnoringModifiers(of: key, modifiers: modifiers),
            isARepeat: false, keyCode: key.keyCode)
    }

    /// Holds or releases modifiers, one `flagsChanged` per modifier, as the keyboard reports them.
    private func sendFlags(_ modifiers: KeyModifiers, phase: KeyPhase) {
        let order: [KeyModifiers] = [.command, .shift, .option, .control].filter { modifiers.contains($0) }
        if phase != .up {
            var held: KeyModifiers = []
            for modifier in order {
                held.insert(modifier)
                sendFlagsChanged(held, keyCode: USKeyboard.modifierKeyCode(modifier))
            }
        }
        if phase != .down {
            var held = modifiers
            for modifier in order.reversed() {
                held.remove(modifier)
                sendFlagsChanged(held, keyCode: USKeyboard.modifierKeyCode(modifier))
            }
        }
    }

    private func sendFlagsChanged(_ held: KeyModifiers, keyCode: UInt16) {
        guard
            let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: held.flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
        else { return }
        // Local event monitors (the rail's hold-⌘ hints) see NSApp.sendEvent, not window.sendEvent.
        NSApp.sendEvent(event)
    }

    private static var eventNumber = 0

    private static func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }
}

/// Sends actions the way AppKit would if the window were key, for when the app is inactive and
/// `NSApp.keyWindow` is nil (see `EventSynthesizer.performMenuItem`).
struct ActionRouter {
    let window: NSWindow

    /// The object that handles `action`: along the first responder's chain, then the content view's chain
    /// (which reaches the window's view controllers), then the window's delegate, the application and its
    /// delegate. Controllers on a chain win over views: NSSplitView answers `toggleSidebar:` itself but
    /// only acts while its window is key, whereas its NSSplitViewController always acts.
    func target(for action: Selector) -> AnyObject? {
        let chains = [window.firstResponder, window.contentView].map { start in
            sequence(first: start, next: { $0?.nextResponder }).compactMap { $0 }
        }
        // The focused view itself wins when it handles the action (⌘F in an editor must reach that
        // editor, not a terminal's find bar further along another chain).
        if let first = window.firstResponder, !(first is NSWindow), first.responds(to: action) {
            return first
        }
        for chain in chains {
            let handlers = chain.filter { $0.responds(to: action) }
            if let controller = handlers.first(where: { $0 is NSViewController || $0 is NSWindowController }) {
                return controller
            }
            if let handler = handlers.first { return handler }
        }
        if let delegate = window.delegate, delegate.responds(to: action) { return delegate }
        if NSApp.responds(to: action) { return NSApp }
        if let delegate = NSApp.delegate, delegate.responds(to: action) { return delegate }
        return nil
    }

    func isEnabled(_ item: NSValidatedUserInterfaceItem, target: AnyObject) -> Bool {
        if let menuItem = item as? NSMenuItem, let validator = target as? NSMenuItemValidation {
            return validator.validateMenuItem(menuItem)
        }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    /// Sends a control's action to its target, or along the window's chain when it has none.
    func sendAction(of control: NSControl) -> Bool {
        guard control.isEnabled, let action = control.action,
            let target = control.target ?? target(for: action)
        else { return false }
        return NSApp.sendAction(action, to: target, from: control)
    }
}
