import AppKit
import PDFKit

/// Paints the Read Aloud sentence and spoken word above a `PDFView`.
///
/// The rects live in page space, so scrolling, zooming, and resizing only
/// re-project them. Nothing here touches `PDFPage.annotations`, so the user's
/// highlights never move or flicker while the voice reads. Hits fall through.
///
/// PDF pages always render light (Reader does not invert them), so this uses
/// the "PDF (Light Page)" tokens from SPEC.md Part 2 §3, an indigo that none of
/// the six highlight swatches or the selection blue share.
final class PDFTTSOverlay: NSView {
    struct Highlight {
        var page: PDFPage
        /// One rect per line, in `page` coordinates.
        var sentence: [NSRect]
        var word: [NSRect]
    }

    weak var pdfView: PDFView?
    var highlight: Highlight? {
        didSet { needsDisplay = true }
    }

    private let sentenceFill = NSColor(srgbRed: 67 / 255, green: 83 / 255, blue: 1, alpha: 0.10)
    private let wordFill = NSColor(srgbRed: 67 / 255, green: 83 / 255, blue: 1, alpha: 0.28)
    private let wordUnderline = NSColor(srgbRed: 55 / 255, green: 68 / 255, blue: 224 / 255, alpha: 0.78)
    private let cornerRadius: CGFloat = 3
    private let underlineThickness: CGFloat = 1.5

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the rects sit in this view, for scroll targeting.
    func viewRects(_ pageRects: [NSRect], on page: PDFPage) -> [NSRect] {
        guard let pdfView else { return [] }
        return pageRects.map { convert(pdfView.convert($0, from: page), from: pdfView) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let highlight else { return }
        sentenceFill.setFill()
        for rect in viewRects(highlight.sentence, on: highlight.page) where rect.intersects(dirtyRect) {
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        for rect in viewRects(highlight.word, on: highlight.page) where rect.intersects(dirtyRect) {
            wordFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            wordUnderline.setFill()
            let bar = NSRect(x: rect.minX, y: rect.maxY - underlineThickness, width: rect.width, height: underlineThickness)
            NSBezierPath(roundedRect: bar, xRadius: underlineThickness / 2, yRadius: underlineThickness / 2).fill()
        }
    }
}
