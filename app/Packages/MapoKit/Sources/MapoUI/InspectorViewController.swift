import AppKit
import MapoClient
import MapoProtocol

/// The inspector (UX §5): the Files | Changes segments above the selected segment's view. ⌥⌘0 shows it.
///
/// The segments sit at the top of the inspector content, 50 pt below its top edge, the fallback UX §2.1
/// allows, rather than in the toolbar. Changes is `ChangesViewController` (T4.3).
public final class InspectorViewController: NSViewController {
    public enum Segment: String {
        case files
        case changes
    }

    private let files: FilesViewController
    private let changes: ChangesViewController
    private let segments = InspectorSegmentControl()
    private let defaultsKey: String
    public private(set) var segment: Segment

    public init(client: MapoClient) {
        self.files = FilesViewController(client: client)
        self.changes = ChangesViewController(client: client)
        DiffPanes.configure(client: client)
        let key = "inspector.segment.\(client.store.instance)"
        self.defaultsKey = key
        self.segment = UserDefaults.standard.string(forKey: key).flatMap(Segment.init) ?? .files
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InspectorViewController is built in code")
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        root.prefersCompactControlSizeMetrics = true
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityIdentifier(AXID.inspector)
        root.setAccessibilityLabel("Inspector")

        addChild(files)
        addChild(changes)
        changes.onCountChange = { [weak self] count in self?.segments.changesCount = count }
        segments.onSelect = { [weak self] segment in self?.select(segment) }
        for view in [segments, files.view, changes.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            segments.topAnchor.constraint(equalTo: root.topAnchor, constant: 50),
            segments.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            segments.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            segments.heightAnchor.constraint(equalToConstant: 30),
            files.view.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 10),
            files.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            files.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            files.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            changes.view.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 10),
            changes.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            changes.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            changes.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        select(segment)
    }

    /// Shows a segment and remembers it for this instance (UX §5.1).
    public func select(_ segment: Segment) {
        self.segment = segment
        UserDefaults.standard.set(segment.rawValue, forKey: defaultsKey)
        segments.selected = segment
        files.view.isHidden = segment != .files
        changes.view.isHidden = segment != .changes
    }

    /// Serves `explorer.refresh` and `explorer.collapse`, which the daemon routes to the app (PROTOCOL §6.5).
    public func handleExplorer(_ request: DaemonRequest) async -> Result<JSONValue, RPCError> {
        _ = view
        switch request.method {
        case "explorer.refresh": return .success(await files.explorerRefresh())
        case "explorer.collapse": return .success(files.explorerCollapse())
        default: return .failure(RPCError(kind: .invalidArgument, message: "The app doesn't handle \(request.method)"))
        }
    }
}

/// The Files | Changes capsule (UX §5.1): 30 tall, padding 2, radius 15, one radio button per segment.
final class InspectorSegmentControl: NSView {
    var onSelect: ((InspectorViewController.Segment) -> Void)?
    var selected: InspectorViewController.Segment = .files {
        didSet { update() }
    }
    /// The Changes badge (UX §5.1): shown when above zero.
    var changesCount = 0 {
        didSet { if changesCount != oldValue { buttons.first { $0.0 == .changes }?.1.badge = changesCount } }
    }
    private let buttons: [(InspectorViewController.Segment, SegmentButton)] = [
        (.files, SegmentButton(title: "Files", identifier: AXID.inspectorSegmentFiles)),
        (.changes, SegmentButton(title: "Changes", identifier: AXID.inspectorSegmentChanges)),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Inspector Segments")
        let stack = NSStackView(views: buttons.map(\.1))
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        for (segment, button) in buttons {
            button.onPress = { [weak self] in self?.onSelect?(segment) }
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InspectorSegmentControl is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Tokens.hover.cgColor
        layer?.borderColor = Tokens.paneHairline.cgColor
    }

    private func update() {
        for (segment, button) in buttons { button.isOn = segment == selected }
        needsDisplay = true
    }
}

/// One segment: 13 pt text, semibold on a fill when selected. A radio button to accessibility, whose value
/// is 1 when selected.
final class SegmentButton: NSButton {
    var onPress: (() -> Void)?
    var isOn = false {
        didSet { update() }
    }
    /// A count after the title, such as Changes' changed files; zero hides it.
    var badge = 0 {
        didSet { update() }
    }

    /// The title without the badge.
    private var label = ""

    init(title: String, identifier: String) {
        super.init(frame: .zero)
        label = title
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 13
        target = self
        action = #selector(pressed)
        setAXIdentifier(identifier)
        setAccessibilityRole(.radioButton)
        cell?.setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SegmentButton is built in code")
    }

    @objc private func pressed() {
        onPress?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    private func update() {
        let color = isOn ? Tokens.textPrimary : Tokens.textSecondaryOnSelection
        let text = NSMutableAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: isOn ? .semibold : .regular), .foregroundColor: color,
            ])
        if badge > 0 {
            text.append(
                NSAttributedString(
                    string: "  \(badge)",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: Tokens.textSecondary,
                    ]))
        }
        attributedTitle = text
        setAccessibilityLabel(badge > 0 ? "\(label), \(badge)" : label)
        setAccessibilityValue(isOn ? 1 : 0)
        cell?.setAccessibilityValue(isOn ? 1 : 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isOn ? Tokens.pressed.cgColor : NSColor.clear.cgColor
        }
    }
}
