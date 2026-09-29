import AppKit
import MapoClient

extension NSPasteboard.PasteboardType {
    /// The rail's private drag type: the dragged row's key, such as `tab:<id>` (UX §3.4).
    static let railRow = NSPasteboard.PasteboardType("dev.mapo.native.rail-row")
}

/// Drag reorder (UX §3.4): tabs within their own workspace through `tab.move`, workspaces among workspace
/// rows through `workspace.move`. Any other drop is refused and the row snaps back.
extension RailViewController {
    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (
        any NSPasteboardWriting
    )? {
        guard let item = item as? RailItem, item.row.isWorkspace || item.row.isTab, renameField == nil else {
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.row.key, forType: .railRow)
        return pasteboardItem
    }

    public func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
        hideHints()
        outlineView.draggingDestinationFeedbackStyle =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .regular : .gap
    }

    public func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard item == nil, let key = draggedKey(info), dropIndex(for: key, at: index) != nil else { return [] }
        return .move
    }

    public func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        guard item == nil, let key = draggedKey(info), let target = dropIndex(for: key, at: index),
            let row = items.first(where: { $0.row.key == key })?.row, let id = row.modelId
        else { return false }
        revealKey = key
        if row.isWorkspace {
            run("Move Workspace") { try await $0.moveWorkspace(id: id, to: target) }
        } else {
            run("Move Tab") { try await $0.moveTab(id: id, to: target) }
        }
        return true
    }

    private func draggedKey(_ info: any NSDraggingInfo) -> String? {
        guard info.draggingSource as? NSOutlineView === outline else { return nil }
        return info.draggingPasteboard.string(forType: .railRow)
    }

    /// The zero-based position a drop before `items[childIndex]` gives the dragged row among its siblings,
    /// or nil when that spot isn't among them: a tab outside its workspace's rows, or a workspace between
    /// another workspace's tabs.
    func dropIndex(for key: String, at childIndex: Int) -> Int? {
        guard childIndex >= 0, childIndex <= items.count,
            let dragged = items.first(where: { $0.row.key == key })?.row
        else { return nil }
        let before = items[..<childIndex].map(\.row)
        if dragged.isWorkspace {
            // Only before a workspace row, or at the very end.
            guard childIndex == items.count || items[childIndex].row.isWorkspace else { return nil }
            return before.filter { $0.isWorkspace && $0.key != key }.count
        }
        guard let workspaceId = dragged.workspaceId else { return nil }
        let siblings = items.indices.filter { items[$0].row.isTab && items[$0].row.workspaceId == workspaceId }
        guard let first = siblings.first, let last = siblings.last, childIndex >= first, childIndex <= last + 1 else {
            return nil
        }
        return before.filter { $0.isTab && $0.workspaceId == workspaceId && $0.key != key }.count
    }
}
