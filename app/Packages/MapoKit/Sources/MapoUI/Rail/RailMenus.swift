import AppKit
import MapoClient
import MapoProtocol

/// Runs a menu item's closure. The item keeps it alive as its `representedObject`, since `target` is weak.
final class RailMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func perform(_ sender: Any?) {
        handler()
    }
}

/// A menu item that runs a closure.
func railMenuItem(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
    let action = RailMenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(RailMenuAction.perform(_:)), keyEquivalent: "")
    item.target = action
    item.representedObject = action
    return item
}

/// The rail's context menus (UX §3.5). Each item calls a daemon command; items that don't apply are hidden.
extension RailViewController {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        hideHints()
        let index = outline.clickedRow
        let groups: [[NSMenuItem]]
        if items.indices.contains(index), let id = items[index].row.modelId {
            switch items[index].row.kind {
            case .workspace: groups = workspaceMenu(id, key: items[index].row.key)
            case .tab: groups = tabMenu(id, key: items[index].row.key)
            default: groups = []
            }
        } else {
            groups = [[railMenuItem("New Workspace") { [weak self] in self?.actions.newWorkspace() }]]
        }
        for group in groups where !group.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
    }

    /// New Shell Tab · New Agent Tab | Rename | Move Up · Move Down | Delete Workspace.
    private func workspaceMenu(_ id: String, key: String) -> [[NSMenuItem]] {
        guard store.workspace(id: id) != nil else { return [] }
        let position = store.workspaces.firstIndex { $0.id == id } ?? 0
        return [
            [
                railMenuItem("New Shell Tab") { [weak self] in
                    self?.run("New Shell Tab") { try await $0.newTab(inWorkspace: id, kind: "shell") }
                },
                railMenuItem("New Agent Tab") { [weak self] in
                    self?.run("New Agent Tab") { try await $0.newTab(inWorkspace: id, kind: "agent") }
                },
            ],
            [railMenuItem("Rename") { [weak self] in self?.beginRename(key: key) }],
            moveItems(position: position, count: store.workspaces.count, key: key) { client, index in
                try await client.moveWorkspace(id: id, to: index)
            },
            [railMenuItem("Delete Workspace") { [weak self] in self?.deleteWorkspace(id: id) }],
        ]
    }

    /// Delete Workspace, from this menu, the Workspace menu or the palette: asks first when programs run
    /// (UX §3.5).
    public func deleteWorkspace(id: String) {
        guard let workspace = store.workspace(id: id) else { return }
        runConfirming(
            "Delete Workspace", title: "Delete \"\(workspace.name)\"?",
            message: { [weak self] in self?.deleteMessage(workspace) ?? "" }, confirm: "Delete Workspace"
        ) { client, force in
            try await client.deleteWorkspace(id: id, force: force)
        }
    }

    /// Rename · Copy Name · Copy Path · Reveal in Finder | Show to the Right · Show Below | Interrupt Agent ·
    /// Stop Command · Open in Browser · Retry Launch | Move Up · Move Down | Close Tab.
    private func tabMenu(_ id: String, key: String) -> [[NSMenuItem]] {
        guard let tab = store.tabs[id] else { return [] }
        let siblings = store.tabs(inWorkspace: tab.workspaceId)
        let position = siblings.firstIndex { $0.id == id } ?? 0
        var status: [NSMenuItem] = []
        if tab.isAgent, tab.state == .running {
            status.append(
                railMenuItem("Interrupt Agent") { [weak self] in
                    self?.run("Interrupt Agent") { try await $0.tabCommand("tab.interrupt", id: id) }
                })
        }
        if !tab.isAgent, tab.state == .running {
            status.append(
                railMenuItem("Stop Command") { [weak self] in
                    self?.run("Stop Command") { try await $0.tabCommand("tab.stop", id: id) }
                })
        }
        for port in tab.server?.ports ?? [] {
            status.append(
                railMenuItem("Open localhost:\(port)") {
                    if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                })
        }
        if tab.launchError != nil {
            status.append(
                railMenuItem("Retry Launch") { [weak self] in
                    self?.run("Retry Launch") { try await $0.tabCommand("tab.restart", id: id) }
                })
        }
        var show: [NSMenuItem] = []
        if !tab.visible {
            show = [
                railMenuItem("Show to the Right") { [weak self] in
                    self?.run("Show to the Right") { try await $0.showTab(id: id, direction: "right") }
                },
                railMenuItem("Show Below") { [weak self] in
                    self?.run("Show Below") { try await $0.showTab(id: id, direction: "down") }
                },
            ]
        }
        let cwd = tab.cwd
        return [
            [
                railMenuItem("Rename") { [weak self] in self?.beginRename(key: key) },
                railMenuItem("Copy Name") { Self.copy(tab.name) },
                railMenuItem("Copy Path") { Self.copy(cwd) },
                railMenuItem("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
                },
            ],
            show,
            status,
            moveItems(position: position, count: siblings.count, key: key) { client, index in
                try await client.moveTab(id: id, to: index)
            },
            [
                railMenuItem("Close Tab") { [weak self] in
                    let program = self?.store.tabs[id]?.program ?? "A program"
                    self?.runConfirming(
                        "Close Tab", title: "Close \"\(tab.name)\"?",
                        message: { "\(program) is still running in this tab. Closing the tab stops it." },
                        confirm: "Close Tab"
                    ) { client, force in
                        try await client.closeTab(id: id, force: force)
                    }
                }
            ],
        ]
    }

    /// Move Up and Move Down, hidden at the ends of the list. The moved row scrolls into view (UX §3.7).
    private func moveItems(
        position: Int, count: Int, key: String, move: @escaping (MapoClient, Int) async throws -> Void
    ) -> [NSMenuItem] {
        var result: [NSMenuItem] = []
        if position > 0 {
            result.append(
                railMenuItem("Move Up") { [weak self] in
                    self?.revealKey = key
                    self?.run("Move Up") { try await move($0, position - 1) }
                })
        }
        if position < count - 1 {
            result.append(
                railMenuItem("Move Down") { [weak self] in
                    self?.revealKey = key
                    self?.run("Move Down") { try await move($0, position + 1) }
                })
        }
        return result
    }

    /// Runs a command without `force`; when the daemon answers `forbidden` because programs run, asks
    /// through the confirmation sheet and runs it again with `force` (R-TAB-7, R-WS-1).
    private func runConfirming(
        _ name: String, title: String, message: @escaping () -> String, confirm: String,
        _ body: @escaping (MapoClient, Bool) async throws -> Void
    ) {
        guard let client else {
            NSSound.beep()
            return
        }
        Task {
            do {
                try await body(client, false)
            } catch let error as RPCError where error.kind == .forbidden {
                guard let window = view.window,
                    await ConfirmSheet.confirm(on: window, title: title, message: message(), confirm: confirm)
                else { return }
                do {
                    try await body(client, true)
                } catch {
                    MapoLog.shared.warn("\(name) failed: \(error)")
                    NSSound.beep()
                }
            } catch {
                MapoLog.shared.warn("\(name) failed: \(error)")
                NSSound.beep()
            }
        }
    }

    /// "2 tabs are still running programs (claude, npm). Deleting the workspace stops them and closes its
    /// 5 tabs." (UX §3.5).
    private func deleteMessage(_ workspace: WorkspaceSummary) -> String {
        let tabs = store.tabs(inWorkspace: workspace.id)
        let programs = tabs.compactMap(\.program)
        let total = tabs.count == 1 ? "its 1 tab" : "its \(tabs.count) tabs"
        if programs.count == 1 {
            return
                "1 tab is still running a program (\(programs[0])). Deleting the workspace stops it and closes \(total)."
        }
        return
            "\(programs.count) tabs are still running programs (\(programs.joined(separator: ", "))). Deleting the workspace stops them and closes \(total)."
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
