import AppKit

/// The actions Mapo's own menu items send (UX §8). The app delegate implements them; the command table
/// names them with `#selector`, so a typo fails the build.
@objc public protocol MapoCommandActions {
    func openSettings(_ sender: Any?)
    func newWorkspace(_ sender: Any?)
    func newShellTab(_ sender: Any?)
    func newAgentTab(_ sender: Any?)
    func newTabInFolder(_ sender: Any?)
    func showFiles(_ sender: Any?)
    func showChanges(_ sender: Any?)
    func togglePalette(_ sender: Any?)
    func biggerFont(_ sender: Any?)
    func smallerFont(_ sender: Any?)
    func actualSizeFont(_ sender: Any?)
    func previousWorkspace(_ sender: Any?)
    func nextWorkspace(_ sender: Any?)
    func renameWorkspace(_ sender: Any?)
    func setAgentCommand(_ sender: Any?)
    func moveWorkspaceUp(_ sender: Any?)
    func moveWorkspaceDown(_ sender: Any?)
    func deleteWorkspace(_ sender: Any?)
    func nextTabNeedingYou(_ sender: Any?)
    func previousTab(_ sender: Any?)
    func nextTab(_ sender: Any?)
    /// Go to Tab N: the sender's `tag` is N, from 1 to 9.
    func goToTab(_ sender: Any?)
    func renameTab(_ sender: Any?)
    func interruptAgent(_ sender: Any?)
    func stopCommand(_ sender: Any?)
    func closeTab(_ sender: Any?)
    func splitRight(_ sender: Any?)
    func splitDown(_ sender: Any?)
    func focusPaneLeft(_ sender: Any?)
    func focusPaneRight(_ sender: Any?)
    func focusPaneUp(_ sender: Any?)
    func focusPaneDown(_ sender: Any?)
    func equalizePanes(_ sender: Any?)
    func closePane(_ sender: Any?)
}

/// Actions a focused file pane answers on its responder chain (UX §6, §8). Nothing else implements them, so
/// their items are disabled until an editor has focus.
@objc public protocol MapoEditorActions {
    func goToLine(_ sender: Any?)
    func toggleSoftWrap(_ sender: Any?)
    func toggleLineNumbers(_ sender: Any?)
}

/// A shortcut as a US-layout key plus modifiers, the form `mapo ui key` takes (ENGINEERING §4.3).
public struct Shortcut: Equatable {
    public enum Modifier: String, CaseIterable {
        case ctrl, alt, shift, cmd
    }

    /// A chord key name: a single character on the US layout such as `n`, `]` or `=`, or `up`, `down`,
    /// `left`, `right`.
    public let key: String
    public let modifiers: Set<Modifier>

    public init(_ key: String, _ modifiers: Set<Modifier> = [.cmd]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// `cmd+shift+]`, for `mapo ui key`.
    public var chord: String {
        let names = [Modifier.cmd, .shift, .alt, .ctrl].filter(modifiers.contains).map(\.rawValue)
        return (names + [key]).joined(separator: "+")
    }

    /// `⇧⌘]` for menus, the palette and tooltips.
    public var display: String {
        let symbols: [Modifier: String] = [.ctrl: "⌃", .alt: "⌥", .shift: "⇧", .cmd: "⌘"]
        let prefix = Modifier.allCases.filter(modifiers.contains).compactMap { symbols[$0] }.joined()
        let keys = ["up": "↑", "down": "↓", "left": "←", "right": "→", "-": "−"]
        // ⇧⌘= reads as ⌘+, the way AppKit draws it.
        if key == "=", modifiers.contains(.shift) {
            return prefix.replacingOccurrences(of: "⇧", with: "") + "+"
        }
        return prefix + (keys[key] ?? key.uppercased())
    }

    /// The `NSMenuItem` key equivalent and mask. Shifted symbols use the character shift types (`}` for
    /// ⇧]), which is how AppKit matches them; shifted letters keep shift in the mask.
    public var menuEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.cmd) { flags.insert(.command) }
        if modifiers.contains(.alt) { flags.insert(.option) }
        if modifiers.contains(.ctrl) { flags.insert(.control) }
        let arrows = [
            "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey, "left": NSLeftArrowFunctionKey,
            "right": NSRightArrowFunctionKey,
        ]
        if let scalar = arrows[key].flatMap({ UnicodeScalar($0) }) {
            if modifiers.contains(.shift) { flags.insert(.shift) }
            return (String(Character(scalar)), flags)
        }
        if modifiers.contains(.shift) {
            if let shifted = Self.shifted[key] { return (shifted, flags) }
            flags.insert(.shift)
        }
        return (key, flags)
    }

    private static let shifted: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
        "`": "~",
    ]
}

/// One entry of the command table (UX §8, ENGINEERING §4.1): a menu item, a palette command and a row of
/// the `task-t1-8` drive's checklist.
public struct Command {
    public enum Menu: String, CaseIterable {
        case app = "Mapo"
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case workspace = "Workspace"
        case tab = "Tab"
        case pane = "Pane"
        case window = "Window"
    }

    /// Stable, for drives: `file.newWorkspace`, `tab.goTo.3`.
    public let id: String
    public let menu: Menu
    public let title: String
    public let action: Selector
    public let shortcut: Shortcut?
    /// More shortcuts for the same item, such as ⌘= for Bigger; hidden menu items carry them.
    public let alternates: [Shortcut]
    /// The daemon method it calls, `view` for view-only actions, `editor` for the focused file pane's
    /// responder chain, or `system` for AppKit's standard items.
    public let method: String
    /// The milestone that brings the feature; until then the item shows disabled.
    public let milestone: String?
    /// Whether the ⌘K palette lists it: every Mapo-specific item (UX §8).
    public let inPalette: Bool
    /// A palette title when the menu's own changes with state ("Hide Sidebar" / "Show Sidebar").
    public let paletteTitle: String?
    /// A submenu of `menu` that holds the item (Tab › Go to Tab).
    public let submenu: String?
    public let tag: Int
    /// A separator goes above this item.
    public let startsGroup: Bool

    init(
        _ id: String, _ menu: Menu, _ title: String, _ action: Selector, _ shortcut: Shortcut? = nil,
        method: String, alternates: [Shortcut] = [], milestone: String? = nil, inPalette: Bool = true,
        paletteTitle: String? = nil, submenu: String? = nil, tag: Int = 0, startsGroup: Bool = false
    ) {
        self.id = id
        self.menu = menu
        self.title = title
        self.action = action
        self.shortcut = shortcut
        self.alternates = alternates
        self.method = method
        self.milestone = milestone
        self.inPalette = inPalette
        self.paletteTitle = paletteTitle
        self.submenu = submenu
        self.tag = tag
        self.startsGroup = startsGroup
    }

    /// Items AppKit handles, in their standard places.
    static func system(
        _ id: String, _ menu: Menu, _ title: String, _ action: Selector, _ shortcut: Shortcut? = nil,
        tag: Int = 0, startsGroup: Bool = false
    ) -> Command {
        Command(
            id, menu, title, action, shortcut, method: "system", inPalette: false, tag: tag, startsGroup: startsGroup)
    }
}

/// The one command table (T1.8): `MainMenu` builds the menu bar from it, the palette lists its commands,
/// and `ui.snapshot` exposes it as `model.commands` for the `task-t1-8` drive.
public enum CommandTable {
    private typealias A = MapoCommandActions
    private typealias E = MapoEditorActions

    /// Every menu item in menu-bar order. The Services submenu and the Window menu's window list come from
    /// AppKit and aren't here.
    public static let all: [Command] = app + file + edit + view + workspace + tab + pane + window

    private static let app: [Command] = [
        .system("app.about", .app, "About Mapo", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        Command(
            "app.settings", .app, "Settings…", #selector(A.openSettings(_:)), Shortcut(","), method: "file.open",
            startsGroup: true),
        .system("app.hide", .app, "Hide Mapo", #selector(NSApplication.hide(_:)), Shortcut("h"), startsGroup: true),
        .system(
            "app.hideOthers", .app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
            Shortcut("h", [.cmd, .alt])),
        .system("app.showAll", .app, "Show All", #selector(NSApplication.unhideAllApplications(_:))),
        // Quits the app only; the daemon keeps running (PLAN T0.7 step 8).
        .system(
            "app.quit", .app, "Quit Mapo", #selector(NSApplication.terminate(_:)), Shortcut("q"), startsGroup: true),
    ]

    private static let file: [Command] = [
        Command(
            "file.newWorkspace", .file, "New Workspace", #selector(A.newWorkspace(_:)), Shortcut("n", [.cmd, .shift]),
            method: "workspace.create"),
        Command(
            "file.newShellTab", .file, "New Shell Tab", #selector(A.newShellTab(_:)), Shortcut("t"),
            method: "tab.create"),
        Command(
            "file.newAgentTab", .file, "New Agent Tab", #selector(A.newAgentTab(_:)), Shortcut("t", [.cmd, .shift]),
            method: "tab.create"),
        Command(
            "file.newTabInFolder", .file, "New Tab in Folder…", #selector(A.newTabInFolder(_:)),
            Shortcut("t", [.cmd, .alt]), method: "tab.create"),
        Command(
            // `saveDocument:`.
            "file.save", .file, "Save", #selector(NSDocument.save(_:)), Shortcut("s"), method: "editor",
            startsGroup: true),
    ]

    private static let edit: [Command] = [
        .system("edit.undo", .edit, "Undo", Selector(("undo:")), Shortcut("z")),
        .system("edit.redo", .edit, "Redo", Selector(("redo:")), Shortcut("z", [.cmd, .shift])),
        .system("edit.cut", .edit, "Cut", #selector(NSText.cut(_:)), Shortcut("x"), startsGroup: true),
        .system("edit.copy", .edit, "Copy", #selector(NSText.copy(_:)), Shortcut("c")),
        .system("edit.paste", .edit, "Paste", #selector(NSText.paste(_:)), Shortcut("v")),
        .system("edit.selectAll", .edit, "Select All", #selector(NSText.selectAll(_:)), Shortcut("a")),
        Command(
            "edit.find", .edit, "Find", #selector(NSResponder.performTextFinderAction(_:)), Shortcut("f"),
            method: "editor", tag: NSTextFinder.Action.showFindInterface.rawValue, startsGroup: true),
        Command(
            "edit.findReplace", .edit, "Find and Replace", #selector(NSResponder.performTextFinderAction(_:)),
            Shortcut("f", [.cmd, .alt]), method: "editor", tag: NSTextFinder.Action.showReplaceInterface.rawValue),
        Command(
            "edit.findNext", .edit, "Find Next", #selector(NSResponder.performTextFinderAction(_:)), Shortcut("g"),
            method: "editor", inPalette: false, tag: NSTextFinder.Action.nextMatch.rawValue),
        Command(
            "edit.findPrevious", .edit, "Find Previous", #selector(NSResponder.performTextFinderAction(_:)),
            Shortcut("g", [.cmd, .shift]), method: "editor", inPalette: false,
            tag: NSTextFinder.Action.previousMatch.rawValue),
        Command("edit.goToLine", .edit, "Go to Line…", #selector(E.goToLine(_:)), Shortcut("l"), method: "editor"),
    ]

    private static let view: [Command] = [
        // NSSplitViewController retitles these Hide/Show as the columns change.
        Command(
            "view.toggleSidebar", .view, "Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)),
            Shortcut("s", [.cmd, .ctrl]), method: "view", paletteTitle: "Toggle Sidebar"),
        Command(
            "view.toggleInspector", .view, "Show Inspector", #selector(NSSplitViewController.toggleInspector(_:)),
            Shortcut("0", [.cmd, .alt]), method: "view", paletteTitle: "Toggle Inspector"),
        Command("view.showFiles", .view, "Show Files", #selector(A.showFiles(_:)), method: "view"),
        Command("view.showChanges", .view, "Show Changes", #selector(A.showChanges(_:)), method: "view"),
        Command(
            "view.palette", .view, "Go to Tab, File or Command…", #selector(A.togglePalette(_:)), Shortcut("k"),
            method: "view", inPalette: false, startsGroup: true),
        Command(
            "view.bigger", .view, "Bigger", #selector(A.biggerFont(_:)), Shortcut("=", [.cmd, .shift]),
            method: "view", alternates: [Shortcut("=")], startsGroup: true),
        Command("view.smaller", .view, "Smaller", #selector(A.smallerFont(_:)), Shortcut("-"), method: "view"),
        Command(
            "view.actualSize", .view, "Actual Size", #selector(A.actualSizeFont(_:)), Shortcut("0"), method: "view"),
        Command(
            "view.softWrap", .view, "Soft Wrap", #selector(E.toggleSoftWrap(_:)), method: "editor", startsGroup: true),
        Command("view.lineNumbers", .view, "Line Numbers", #selector(E.toggleLineNumbers(_:)), method: "editor"),
        .system(
            "view.fullScreen", .view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)),
            Shortcut("f", [.cmd, .ctrl]), startsGroup: true),
    ]

    private static let workspace: [Command] = [
        Command(
            "workspace.previous", .workspace, "Previous Workspace", #selector(A.previousWorkspace(_:)),
            Shortcut("up", [.cmd, .ctrl]), method: "workspace.activate"),
        Command(
            "workspace.next", .workspace, "Next Workspace", #selector(A.nextWorkspace(_:)),
            Shortcut("down", [.cmd, .ctrl]), method: "workspace.activate"),
        Command(
            "workspace.rename", .workspace, "Rename Workspace", #selector(A.renameWorkspace(_:)),
            method: "workspace.rename", startsGroup: true),
        Command(
            "workspace.setAgentCommand", .workspace, "Set Agent Command…", #selector(A.setAgentCommand(_:)),
            method: "workspace.configure"),
        Command(
            "workspace.moveUp", .workspace, "Move Workspace Up", #selector(A.moveWorkspaceUp(_:)),
            method: "workspace.move", startsGroup: true),
        Command(
            "workspace.moveDown", .workspace, "Move Workspace Down", #selector(A.moveWorkspaceDown(_:)),
            method: "workspace.move"),
        Command(
            "workspace.delete", .workspace, "Delete Workspace", #selector(A.deleteWorkspace(_:)),
            method: "workspace.delete", startsGroup: true),
    ]

    private static let tab: [Command] =
        [
            Command(
                "tab.nextNeedingYou", .tab, "Next Tab That Needs You", #selector(A.nextTabNeedingYou(_:)),
                Shortcut("j"), method: "tab.focus"),
            Command(
                "tab.previous", .tab, "Previous Tab", #selector(A.previousTab(_:)), Shortcut("[", [.cmd, .shift]),
                method: "tab.focus", startsGroup: true),
            Command(
                "tab.next", .tab, "Next Tab", #selector(A.nextTab(_:)), Shortcut("]", [.cmd, .shift]),
                method: "tab.focus"),
        ]
        + (1...9).map { index in
            Command(
                "tab.goTo.\(index)", .tab, "Tab \(index)", #selector(A.goToTab(_:)), Shortcut("\(index)"),
                method: "tab.focus", inPalette: false, submenu: "Go to Tab", tag: index)
        }
        + [
            Command(
                "tab.rename", .tab, "Rename Tab", #selector(A.renameTab(_:)), Shortcut("r", [.cmd, .alt]),
                method: "tab.rename", startsGroup: true),
            Command(
                "tab.interrupt", .tab, "Interrupt Agent", #selector(A.interruptAgent(_:)),
                Shortcut("x", [.cmd, .shift]), method: "tab.interrupt", startsGroup: true),
            Command("tab.stop", .tab, "Stop Command", #selector(A.stopCommand(_:)), Shortcut("."), method: "tab.stop"),
            Command(
                "tab.close", .tab, "Close Tab", #selector(A.closeTab(_:)), Shortcut("w", [.cmd, .shift]),
                method: "tab.close", startsGroup: true),
        ]

    private static let pane: [Command] = [
        Command(
            "pane.splitRight", .pane, "Split Right", #selector(A.splitRight(_:)), Shortcut("d"), method: "pane.split"),
        Command(
            "pane.splitDown", .pane, "Split Down", #selector(A.splitDown(_:)), Shortcut("d", [.cmd, .shift]),
            method: "pane.split"),
        Command(
            "pane.focusLeft", .pane, "Focus Pane Left", #selector(A.focusPaneLeft(_:)), Shortcut("left", [.cmd, .alt]),
            method: "pane.focus", startsGroup: true),
        Command(
            "pane.focusRight", .pane, "Focus Pane Right", #selector(A.focusPaneRight(_:)),
            Shortcut("right", [.cmd, .alt]), method: "pane.focus"),
        Command(
            "pane.focusUp", .pane, "Focus Pane Up", #selector(A.focusPaneUp(_:)), Shortcut("up", [.cmd, .alt]),
            method: "pane.focus"),
        Command(
            "pane.focusDown", .pane, "Focus Pane Down", #selector(A.focusPaneDown(_:)), Shortcut("down", [.cmd, .alt]),
            method: "pane.focus"),
        Command(
            "pane.equalize", .pane, "Equalize Panes", #selector(A.equalizePanes(_:)), method: "pane.equalize",
            startsGroup: true),
        Command("pane.close", .pane, "Close Pane", #selector(A.closePane(_:)), Shortcut("w"), method: "pane.close"),
    ]

    private static let window: [Command] = [
        .system("window.minimize", .window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), Shortcut("m")),
        .system("window.zoom", .window, "Zoom", #selector(NSWindow.performZoom(_:))),
        .system(
            "window.bringAllToFront", .window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)),
            startsGroup: true),
    ]

    /// The entry an item with this action and tag came from.
    public static func command(for action: Selector, tag: Int = 0) -> Command? {
        all.first { $0.action == action && $0.tag == tag }
    }

    /// Whether the entry's feature comes in a later milestone, which keeps its item disabled.
    public static func isLater(_ action: Selector) -> Bool {
        all.contains { $0.action == action && $0.milestone != nil }
    }

    /// `model.commands` in `ui.snapshot`: the checklist `drives/task-t1-8.sh` walks.
    public static var checklist: [[String: String]] {
        all.map { command in
            var row = [
                "id": command.id, "menu": command.menu.rawValue, "title": command.title, "method": command.method,
            ]
            if let shortcut = command.shortcut {
                row["chord"] = shortcut.chord
                row["shortcut"] = shortcut.display
            }
            if let alternate = command.alternates.first { row["alternateChord"] = alternate.chord }
            if let milestone = command.milestone { row["milestone"] = milestone }
            return row
        }
    }
}
