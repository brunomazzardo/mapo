import AppKit

/// The window backdrop (UX §2, §9.1): a vertical `backdrop.top` to `backdrop.bottom` gradient with two
/// radial glows, as the "A · Source list" board draws it: `radial-gradient(1100px 640px at 8% -12%, …,
/// transparent 62%)` and `radial-gradient(900px 620px at 104% 112%, …, transparent 60%)`. It sits under
/// everything in the window and shows through the toolbar band, the pane gutters and the glass. It takes
/// no clicks, so the split view's dividers still get theirs.
final class BackdropView: NSView {
    private let gradient = CAGradientLayer()
    private let topGlow = CAGradientLayer()
    private let bottomGlow = CAGradientLayer()

    /// One glow: the ellipse's center as fractions of the window from the top left, its radii in points,
    /// and where it fades out.
    private struct Glow {
        var center: CGPoint
        var radii: CGSize
        var fadeEnd: NSNumber
    }

    private static let top = Glow(
        center: CGPoint(x: 0.08, y: -0.12), radii: CGSize(width: 1100, height: 640), fadeEnd: 0.62)
    private static let bottom = Glow(
        center: CGPoint(x: 1.04, y: 1.12), radii: CGSize(width: 900, height: 620), fadeEnd: 0.60)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(gradient)
        for (glow, spec) in [(topGlow, Self.top), (bottomGlow, Self.bottom)] {
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.locations = [0, spec.fadeEnd]
            layer?.addSublayer(glow)
        }
        setAccessibilityElement(false)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BackdropView is built in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        topGlow.frame = Self.frame(of: Self.top, in: bounds, flipped: isFlipped)
        bottomGlow.frame = Self.frame(of: Self.bottom, in: bounds, flipped: isFlipped)
        CATransaction.commit()
    }

    /// The glow layer covers the ellipse's bounding box, so the unit-space end point (1, 1) sits one radius
    /// out on each axis.
    private static func frame(of glow: Glow, in bounds: NSRect, flipped: Bool) -> CGRect {
        let x = bounds.minX + glow.center.x * bounds.width
        let fromTop = glow.center.y * bounds.height
        let y = flipped ? bounds.minY + fromTop : bounds.maxY - fromTop
        return CGRect(
            x: x - glow.radii.width, y: y - glow.radii.height, width: glow.radii.width * 2,
            height: glow.radii.height * 2)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // The layer's unit space starts at the bottom on macOS.
            gradient.colors = [Theme.backdropBottom.cgColor, Theme.backdropTop.cgColor]
            for (glow, color) in [
                (topGlow, Theme.backdropGlowTopLeading), (bottomGlow, Theme.backdropGlowBottomTrailing),
            ] {
                // Fade to the same hue at zero alpha, as CSS does, rather than through black.
                glow.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            }
        }
    }
}

/// An opaque `glassOpaque` fill behind a glass panel's content, for when the `[ui] reduce-transparency`
/// override is on and macOS itself doesn't make the glass opaque (UX §9.4).
final class OpaqueGlassView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.glass
        layer?.cornerCurve = .continuous
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OpaqueGlassView is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.glassOpaque.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
