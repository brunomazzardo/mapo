import AppKit
import MapoUI

/// The programmatic menu bar (UX §8), built from `CommandTable`: Mapo, File, Edit, View, Workspace, Tab,
/// Pane and Window. v1 has no Help menu.
enum MainMenu {
    static func build() -> NSMenu {
        let bar = NSMenu()
        for menu in Command.Menu.allCases {
            let built = build(menu, CommandTable.all.filter { $0.menu == menu })
            bar.addItem(submenu(built))
            if menu == .window { NSApp.windowsMenu = built }
        }
        return bar
    }

    private static func build(_ menu: Command.Menu, _ commands: [Command]) -> NSMenu {
        let result = NSMenu(title: menu.rawValue)
        var nested: [String: NSMenu] = [:]
        for command in commands {
            if let name = command.submenu, let existing = nested[name] {
                add(command, to: existing)
                continue
            }
            if command.startsGroup, !result.items.isEmpty { result.addItem(.separator()) }
            if let name = command.submenu {
                let child = NSMenu(title: name)
                nested[name] = child
                result.addItem(submenu(child))
                add(command, to: child)
                continue
            }
            add(command, to: result)
            // Services sits right after About, as in every Mac app.
            if command.id == "app.about" {
                result.addItem(.separator())
                let services = NSMenu(title: "Services")
                result.addItem(submenu(services))
                NSApp.servicesMenu = services
            }
        }
        return result
    }

    /// The item, plus a hidden item per alternate shortcut (⌘= for Bigger) that still answers its key.
    private static func add(_ command: Command, to menu: NSMenu) {
        menu.addItem(item(command, command.shortcut))
        for alternate in command.alternates {
            let hidden = item(command, alternate)
            hidden.isHidden = true
            hidden.allowsKeyEquivalentWhenHidden = true
            menu.addItem(hidden)
        }
    }

    private static func item(_ command: Command, _ shortcut: Shortcut?) -> NSMenuItem {
        let equivalent = shortcut?.menuEquivalent
        let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: equivalent?.key ?? "")
        if let equivalent { item.keyEquivalentModifierMask = equivalent.modifiers }
        item.tag = command.tag
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
