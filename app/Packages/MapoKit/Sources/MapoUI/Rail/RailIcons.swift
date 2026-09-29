import AppKit

/// The rail's kind icons, traced from the canvas as template images (UX §3.1): a 24×24 viewBox, no fill,
/// stroke 1.8, round caps and joins.
enum RailIcons {
    static let agent = image {
        polygon([(12, 3), (13.8, 8.2), (19, 10), (13.8, 11.8), (12, 17), (10.2, 11.8), (5, 10), (10.2, 8.2)])
        polygon([
            (19, 16), (19.7, 17.8), (21.5, 18.5), (19.7, 19.2), (19, 21), (18.3, 19.2), (16.5, 18.5), (18.3, 17.8),
        ])
    }

    static let shell = image {
        polyline([(5, 7), (10, 12), (5, 17)])
        polyline([(12, 18), (19, 18)])
    }

    static let server = image {
        roundedRect(NSRect(x: 4, y: 4, width: 16, height: 7))
        roundedRect(NSRect(x: 4, y: 13, width: 16, height: 7))
        polyline([(8, 7.5), (8.01, 7.5)])
        polyline([(8, 16.5), (8.01, 16.5)])
    }

    static func image(for icon: RailIcon) -> NSImage {
        switch icon {
        case .agent: agent
        case .shell: shell
        case .server: server
        }
    }

    private static func image(_ draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            NSColor.black.setStroke()
            draw()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func path(_ points: [(CGFloat, CGFloat)], closed: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, point) in points.enumerated() {
            let p = NSPoint(x: point.0, y: point.1)
            if index == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        if closed { path.close() }
        return path
    }

    private static func roundedRect(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.lineWidth = 1.8
        path.stroke()
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) {
        path(points, closed: true).stroke()
    }

    private static func polyline(_ points: [(CGFloat, CGFloat)]) {
        path(points, closed: false).stroke()
    }
}
