import AppKit
import PDFKit

/// Image and PDF previews in the file pane (R-FS-6, UX §6.1). Each carries `pane.preview:<absPath>` and takes
/// focus; while focused, ⌘+ (or ⌘=) and ⌘− zoom and ⌘0 fits.
@MainActor
protocol FilePreview: NSView {
    /// The header meta, such as "1280 × 800 · 214 KB" or "12 pages".
    var meta: String { get }
    var focusView: NSView { get }
}

/// A raster image, centered and fitted but never above 100%, over an 8 pt checkerboard.
final class ImagePreviewView: NSView, FilePreview {
    private let scroll = PreviewScrollView()
    private let canvas = CheckerImageView()
    private(set) var meta = ""

    init(path: String, data: Data, theme: EditorTheme) {
        super.init(frame: .zero)
        let image = NSImage(data: data) ?? NSImage()
        let rep = image.representations.first
        let pixels = NSSize(
            width: rep?.pixelsWide ?? Int(image.size.width), height: rep?.pixelsHigh ?? Int(image.size.height))
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        meta = "\(Int(pixels.width)) × \(Int(pixels.height)) · \(bytes)"
        canvas.image = image
        canvas.checker = theme.checker
        canvas.frame = NSRect(origin: .zero, size: image.size)
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 16
        scroll.onFit = { [weak self] in self?.fit() }
        scroll.setAccessibilityIdentifier(EditorAXID.preview(path))
        scroll.setAccessibilityLabel("\((path as NSString).lastPathComponent), \(meta)")
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ImagePreviewView is built in code")
    }

    var focusView: NSView { scroll }

    private var fitted = true

    override func layout() {
        super.layout()
        scroll.frame = bounds
        if fitted { fit() }
    }

    /// Fits the image in the pane, never above 100% (⌘0).
    func fit() {
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0, scroll.bounds.width > 0 else { return }
        let scale = min(1, min(scroll.bounds.width / size.width, scroll.bounds.height / size.height))
        scroll.magnification = scale
        fitted = true
    }

    override func magnify(with event: NSEvent) {
        fitted = false
        super.magnify(with: event)
    }
}

/// The preview's scroll view: focusable, with the zoom keys.
final class PreviewScrollView: NSScrollView {
    var onFit: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleZoom(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleZoom(event) { super.keyDown(with: event) }
    }

    private func handleZoom(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers else {
            return false
        }
        switch key {
        case "+", "=": setMagnification(min(maxMagnification, magnification * 1.25), centeredAt: center)
        case "-": setMagnification(max(minMagnification, magnification / 1.25), centeredAt: center)
        case "0": onFit?()
        default: return false
        }
        return true
    }

    private var center: NSPoint {
        let visible = documentVisibleRect
        return NSPoint(x: visible.midX, y: visible.midY)
    }
}

/// Keeps a document smaller than the view in its middle.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

/// The image over an 8 pt checkerboard, which shows through transparent pixels.
final class CheckerImageView: NSView {
    var image: NSImage?
    var checker = NSColor.clear

    override func draw(_ dirtyRect: NSRect) {
        checker.setFill()
        let size: CGFloat = 8
        var y = floor(dirtyRect.minY / size) * size
        while y < dirtyRect.maxY {
            var x = floor(dirtyRect.minX / size) * size
            while x < dirtyRect.maxX {
                if (Int(x / size) + Int(y / size)).isMultiple(of: 2) {
                    NSRect(x: x, y: y, width: size, height: size).fill()
                }
                x += size
            }
            y += size
        }
        image?.draw(in: bounds)
    }
}

/// A PDF: PDFKit's `PDFView`, continuous and auto-scaled.
final class PDFPreviewView: NSView, FilePreview {
    private let pdf = PreviewPDFView()
    private(set) var meta = ""

    init(path: String, data: Data) {
        super.init(frame: .zero)
        let document = PDFDocument(data: data)
        pdf.document = document
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displaysPageBreaks = true
        pdf.backgroundColor = .clear
        let pages = document?.pageCount ?? 0
        meta = pages == 1 ? "1 page" : "\(pages) pages"
        pdf.setAccessibilityIdentifier(EditorAXID.preview(path))
        pdf.setAccessibilityLabel("\((path as NSString).lastPathComponent), \(meta)")
        addSubview(pdf)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PDFPreviewView is built in code")
    }

    var focusView: NSView { pdf }

    override func layout() {
        super.layout()
        pdf.frame = bounds
    }
}

/// PDFView with ⌘0 back to auto-scaling (⌘+ and ⌘− are PDFView's own zoom keys).
final class PreviewPDFView: PDFView {
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "0" {
            autoScales = true
            return
        }
        super.keyDown(with: event)
    }
}
