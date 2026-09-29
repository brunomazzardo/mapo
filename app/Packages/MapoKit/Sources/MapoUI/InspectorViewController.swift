import AppKit

/// The inspector (UX §5), a collapsed placeholder until Files and Changes land in M1. ⌥⌘0 shows it.
public final class InspectorViewController: NSViewController {
    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        root.prefersCompactControlSizeMetrics = true
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityIdentifier(AXID.inspector)
        root.setAccessibilityLabel("Inspector")
        view = root
    }
}
