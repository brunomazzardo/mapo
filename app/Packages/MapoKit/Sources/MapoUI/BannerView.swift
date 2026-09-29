import AppKit
import MapoClient

/// `app.banner` (UX §4.3): a 32 pt glass bar at the top of the panes area while the control connection is
/// down. "Reconnecting to mapod…" first; after 10 s "Can't reach mapod. Mapo keeps retrying." with
/// [Restart mapod] (`app.banner.action`). A protocol mismatch explains itself and offers the same button.
final class BannerView: NSView {
    /// The banner's states, exposed as its AX value.
    enum Phase: String, Equatable {
        case hidden
        case reconnecting
        case unreachable
        case protocolMismatch = "protocol-mismatch"
    }

    static let unreachableAfter: TimeInterval = 10

    var onRestart: (() -> Void)?
    private(set) var phase = Phase.hidden

    private let glass = NSGlassEffectView()
    private let message = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Restart mapod", target: nil, action: nil)
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = 14
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        message.font = .systemFont(ofSize: 12)
        message.textColor = Tokens.textBody
        message.lineBreakMode = .byTruncatingTail
        message.setAccessibilityElement(false)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.target = self
        button.action = #selector(restart)
        button.setAXIdentifier(AXID.appBannerAction)
        let stack = NSStackView(views: [message, button])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)
        glass.contentView = stack

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
            glass.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AXID.appBanner)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BannerView is built in code")
    }

    /// Shows the state for `connection`, re-rendering by itself when the 10 s mark passes.
    func update(connection: AppStore.Connection, restarting: Bool) {
        timer?.invalidate()
        timer = nil
        let next: Phase
        let text: String
        switch connection {
        case .connecting, .connected:
            next = .hidden
            text = ""
        case .reconnecting(let since):
            let elapsed = Date().timeIntervalSince(since)
            if elapsed < Self.unreachableAfter {
                next = .reconnecting
                text = "Reconnecting to mapod…"
                timer = Timer.scheduledTimer(withTimeInterval: Self.unreachableAfter - elapsed, repeats: false) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.update(connection: connection, restarting: restarting)
                    }
                }
            } else {
                next = .unreachable
                text = "Can't reach mapod. Mapo keeps retrying."
            }
        case .protocolMismatch(let daemon, let app):
            next = .protocolMismatch
            text =
                "mapod is from another build (protocol \(daemon), app \(app)). "
                + "Restart it to continue. Shell commands stop; agents resume."
        }
        message.stringValue = text
        button.isHidden = next == .hidden || next == .reconnecting
        button.isEnabled = !restarting
        button.title = restarting ? "Restarting…" : "Restart mapod"
        setAccessibilityLabel(text)
        setAccessibilityValue(next.rawValue)
        guard next != phase else { return }
        let wasHidden = phase == .hidden
        phase = next
        if next == .hidden {
            isHidden = true
        } else if wasHidden {
            show()
        }
        if next != .hidden {
            NSAccessibility.post(
                element: self, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func show() {
        isHidden = false
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = 1
            return
        }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    @objc private func restart() {
        onRestart?()
    }
}
