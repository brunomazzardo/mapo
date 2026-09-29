import AppKit
import MapoClient

/// The toolbar title, item 5 of UX §2.1 (`toolbar.title`): the active workspace's name over a subtitle such as
/// "dev-mapo-native · 5 tabs · backend, frontend". It speaks both lines as its label.
public final class ToolbarTitleView: NSView {
    private let store: AppStore
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    public init(store: AppStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = Tokens.textPrimary
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = Tokens.textSecondary
        for label in [name, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
            label.cell?.setAccessibilityElement(false)
        }
        let stack = NSStackView(views: [name, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityElement(false)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AXID.toolbarTitle)
        observeContinuously(self) { $0.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolbarTitleView is built in code")
    }

    private func render() {
        guard let workspace = store.activeWorkspace else {
            name.stringValue = store.hasSnapshot ? "No Workspace" : "Mapo"
            subtitle.stringValue = store.instance == "main" ? "" : store.instance
            finish()
            return
        }
        let tabs = store.tabs(inWorkspace: workspace.id)
        var parts: [String] = []
        if store.instance != "main" { parts.append(store.instance) }
        switch tabs.count {
        case 0: parts.append("No tabs")
        case 1: parts.append("1 tab")
        default: parts.append("\(tabs.count) tabs")
        }
        var folders: [String] = []
        for tab in tabs {
            let folder = RailModel.abbreviateHome(tab.cwd) == "~" ? "~" : (tab.cwd as NSString).lastPathComponent
            if !folder.isEmpty, !folders.contains(folder) { folders.append(folder) }
        }
        if !folders.isEmpty {
            let shown = folders.prefix(3).joined(separator: ", ")
            parts.append(folders.count > 3 ? "\(shown) +\(folders.count - 3)" : shown)
        }
        name.stringValue = workspace.name
        subtitle.stringValue = parts.joined(separator: " · ")
        finish()
    }

    /// Colors the instance name in `accent` (UX §2.1), hides an empty subtitle and sets the spoken label.
    private func finish() {
        let text = subtitle.stringValue
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Tokens.textSecondary])
        if store.instance != "main", text.hasPrefix(store.instance) {
            attributed.addAttribute(
                .foregroundColor, value: Tokens.accent, range: NSRange(location: 0, length: store.instance.utf16.count))
        }
        subtitle.attributedStringValue = attributed
        subtitle.isHidden = subtitle.stringValue.isEmpty
        let spoken = [name.stringValue, subtitle.stringValue].filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityLabel(spoken)
    }
}
