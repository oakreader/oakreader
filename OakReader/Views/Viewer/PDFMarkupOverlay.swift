import Foundation
import PDFKit
import AppKit

/// Text-markup highlight rendered as a DB-backed *overlay* rather than a native
/// `PDFAnnotation` baked into the file.
///
/// Why an overlay instead of `page.addAnnotation`:
///  - The original PDF on disk stays byte-identical (good for hashing/dedup,
///    citations, re-sharing the untouched source) — no `markDocumentEdited`,
///    no rewriting a large file on every highlight.
///  - The DB (`annotations` table, `positionKind: "pdf-overlay"`) is the single
///    source of truth, matching how web/live highlights already work.
///  - We control the blend ourselves, so the color is *stable* across page
///    switches. Native `.highlight` annotations shift color the first time
///    PDFKit generates their appearance stream (live flat-fill → cached
///    Multiply-blend), which is the "color changed when I switched pages" bug.
enum PDFMarkupKind: String {
    case highlight
    case underline
    case strikethrough
}

/// A single text-markup, positioned in PDF page coordinate space (origin
/// bottom-left). `quads` are the per-line rectangles covering the text.
struct PDFTextMarkup: Identifiable {
    let id: String
    let kind: PDFMarkupKind
    let quads: [CGRect]
    /// Marker color, already carrying its intended alpha.
    let color: NSColor
    /// The underlying text covered by the markup (for the sidebar list).
    var text: String?
    /// A user comment. Non-nil ⇒ this markup is a *note*: it draws a clickable
    /// marker and clicking it opens the Markdown comment editor.
    var comment: String?

    var isNote: Bool { comment != nil }

    /// Rect (page coordinate space) of the clickable note marker, drawn just
    /// past the end of the last line. `nil` when this isn't a note.
    var noteMarkerRect: CGRect? {
        guard isNote, let last = quads.last else { return nil }
        let side = max(9, min(16, last.height * 0.9))
        return CGRect(x: last.maxX + 2, y: last.maxY - side, width: side, height: side)
    }
}

extension PDFMarkupKind {
    /// Maps to the PDFKit subtype rawValue ("Highlight" / "Underline" /
    /// "StrikeOut") so overlay markups share the sidebar's type labels.
    var subtype: PDFAnnotationSubtype {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikethrough: return .strikeOut
        }
    }
}

/// Vends the markups for a given page index to the custom `PDFPage` subclass.
protocol PDFMarkupOverlaySource: AnyObject {
    func textMarkups(forPageIndex index: Int) -> [PDFTextMarkup]
}

// MARK: - Overlay Page

/// `PDFPage` subclass that draws the DB-backed text markups on top of the page
/// content. Installed via `PDFDocument.delegate.classForPage()`. Drawing moves
/// with the page for free across scroll / zoom / thumbnails / print.
final class OverlayPDFPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)

        guard let doc = document,
              let source = doc.delegate as? PDFMarkupOverlaySource else { return }
        let index = doc.index(for: self)
        let markups = source.textMarkups(forPageIndex: index)
        guard !markups.isEmpty else { return }

        // The context is already in this page's user space for `box`.
        context.saveGState()
        for markup in markups {
            draw(markup, in: context)
        }
        context.restoreGState()
    }

    private func draw(_ markup: PDFTextMarkup, in context: CGContext) {
        // Transient flash: clicking a note card pulses the note's source range so
        // you can see *where* it came from, then it fades — no persistent paint.
        if let controller = document?.delegate as? PDFMarkupOverlayController,
           let alpha = controller.flashAlpha(forId: markup.id) {
            drawFlash(markup, alpha: alpha, in: context)
        }

        // A note anchors to a selection but must NOT paint over the source text —
        // the quote lives in the note card; the page only gets the small clickable
        // marker (for jump-back / click-to-edit). Only a *plain* highlight (no
        // comment) draws the colored fill/stroke decoration.
        if let markerRect = markup.noteMarkerRect {
            // Neutral grey badge (not the highlight hue): the marker is a UI
            // affordance — "a note lives here" — not a colored highlight. Mirrors
            // the app's secondary-text token (≈ `Color.primary.opacity(0.6)`).
            drawNoteMarker(markerRect, color: Self.noteMarkerColor, in: context)
        } else {
            drawDecoration(markup, in: context)
        }
    }

    /// Draw the transient reveal fill for a flashing markup (same multiply blend
    /// as a highlight, but at a caller-controlled, fading alpha).
    private func drawFlash(_ markup: PDFTextMarkup, alpha: CGFloat, in context: CGContext) {
        context.setBlendMode(.multiply)
        context.setFillColor(markup.color.withAlphaComponent(alpha).cgColor)
        for quad in markup.quads {
            context.fill(quad)
        }
    }

    /// Neutral grey for the note marker badge. Drawn on the (light) page, so a
    /// fixed ~60%-black grey reads the same regardless of app appearance —
    /// matching `OakStyle.Colors.textSecondary` (`Color.primary.opacity(0.6)`).
    static let noteMarkerColor = NSColor(calibratedWhite: 0.4, alpha: 1)

    /// Draws a small "comment bubble" marker indicating a note is attached.
    private func drawNoteMarker(_ rect: CGRect, color: NSColor, in context: CGContext) {
        context.setBlendMode(.normal)
        let body = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.25, yRadius: rect.width * 0.25)
        context.addPath(body.cgPath)
        context.setFillColor(color.withAlphaComponent(1).cgColor)
        context.fillPath()

        // Two dots to read as a speech bubble.
        let dot = max(1, rect.width * 0.12)
        context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        for fraction in [0.34, 0.62] {
            let cx = rect.minX + rect.width * fraction
            let cy = rect.midY
            context.fillEllipse(in: CGRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot))
        }
    }

    private func drawDecoration(_ markup: PDFTextMarkup, in context: CGContext) {
        switch markup.kind {
        case .highlight:
            // Multiply keeps the underlying glyphs readable through the marker,
            // and — unlike PDFKit's lazy appearance stream — looks identical on
            // every redraw, so the color never shifts on page switch.
            context.setBlendMode(.multiply)
            context.setFillColor(markup.color.cgColor)
            for quad in markup.quads {
                context.fill(quad)
            }
        case .underline:
            strokeLines(for: markup, in: context) { quad in
                let y = quad.minY + max(1, quad.height * 0.08)
                return (CGPoint(x: quad.minX, y: y), CGPoint(x: quad.maxX, y: y))
            }
        case .strikethrough:
            strokeLines(for: markup, in: context) { quad in
                let y = quad.midY
                return (CGPoint(x: quad.minX, y: y), CGPoint(x: quad.maxX, y: y))
            }
        }
    }

    private func strokeLines(
        for markup: PDFTextMarkup,
        in context: CGContext,
        line: (CGRect) -> (CGPoint, CGPoint)
    ) {
        context.setBlendMode(.normal)
        context.setStrokeColor(markup.color.cgColor)
        for quad in markup.quads {
            let width = max(1, quad.height * 0.06)
            context.setLineWidth(width)
            let (start, end) = line(quad)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
    }
}

// MARK: - Overlay Controller

/// Owns the in-memory markup set, vends the `OverlayPDFPage` class, and triggers
/// redraws. One instance per document, set as `pdfDocument.delegate`.
final class PDFMarkupOverlayController: NSObject, PDFDocumentDelegate, PDFMarkupOverlaySource {
    private var byPage: [Int: [PDFTextMarkup]] = [:]
    weak var pdfView: PDFView?

    // MARK: Transient flash (click-to-reveal a note's source)

    private var flashId: String?
    private var flashStart: Date?
    private var flashTimer: Timer?
    /// Hold at full strength briefly (so it's visible after a scroll/page jump
    /// settles), then fade out.
    private let flashHold: TimeInterval = 0.35
    private let flashFade: TimeInterval = 0.85
    private let flashPeak: CGFloat = 0.5

    /// The fill alpha to use for `id` right now, or nil if it isn't flashing.
    /// Read by `OverlayPDFPage` while a flash fades.
    func flashAlpha(forId id: String) -> CGFloat? {
        guard id == flashId, let start = flashStart else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed <= flashHold { return flashPeak }
        let t = min(1, (elapsed - flashHold) / flashFade)
        return flashPeak * (1 - CGFloat(t))
    }

    /// Briefly pulse a markup's source range, then fade it out — the reveal a
    /// note card triggers when clicked, since notes leave no persistent paint.
    func flash(id: String) {
        flashTimer?.invalidate()
        flashId = id
        flashStart = Date()
        redraw()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, let start = self.flashStart else { timer.invalidate(); return }
            if Date().timeIntervalSince(start) >= self.flashHold + self.flashFade {
                self.flashId = nil
                self.flashStart = nil
                timer.invalidate()
                self.flashTimer = nil
            }
            self.redraw()
        }
    }

    // MARK: PDFDocumentDelegate

    func classForPage() -> AnyClass {
        OverlayPDFPage.self
    }

    // MARK: PDFMarkupOverlaySource

    func textMarkups(forPageIndex index: Int) -> [PDFTextMarkup] {
        byPage[index] ?? []
    }

    // MARK: Mutation

    /// Replace the entire set (used on initial load from the DB).
    func load(_ markupsByPage: [Int: [PDFTextMarkup]]) {
        byPage = markupsByPage
        redraw()
    }

    func add(_ markup: PDFTextMarkup, page index: Int) {
        byPage[index, default: []].append(markup)
        redraw()
    }

    func remove(id: String) {
        for key in byPage.keys {
            byPage[key]?.removeAll { $0.id == id }
        }
        redraw()
    }

    func updateColor(id: String, color: NSColor) {
        mutate(id: id) { PDFTextMarkup(id: $0.id, kind: $0.kind, quads: $0.quads, color: color, text: $0.text, comment: $0.comment) }
    }

    func updateComment(id: String, comment: String?) {
        mutate(id: id) { PDFTextMarkup(id: $0.id, kind: $0.kind, quads: $0.quads, color: $0.color, text: $0.text, comment: comment) }
    }

    func updateKind(id: String, kind: PDFMarkupKind) {
        mutate(id: id) { PDFTextMarkup(id: $0.id, kind: kind, quads: $0.quads, color: $0.color, text: $0.text, comment: $0.comment) }
    }

    private func mutate(id: String, _ transform: (PDFTextMarkup) -> PDFTextMarkup) {
        for (key, markups) in byPage {
            byPage[key] = markups.map { $0.id == id ? transform($0) : $0 }
        }
        redraw()
    }

    /// Look up a markup and its page by DB id (used to anchor the note editor).
    func markup(withId id: String) -> (pageIndex: Int, markup: PDFTextMarkup)? {
        for (page, markups) in byPage {
            if let found = markups.first(where: { $0.id == id }) {
                return (page, found)
            }
        }
        return nil
    }

    /// All markups paired with their page index — used to build the sidebar list.
    func allMarkups() -> [(pageIndex: Int, markup: PDFTextMarkup)] {
        byPage.flatMap { page, markups in markups.map { (page, $0) } }
    }

    /// Hit-test a point (in page coordinate space) on a given page; returns the
    /// topmost markup whose quads contain the point.
    func markup(at point: CGPoint, pageIndex: Int) -> PDFTextMarkup? {
        guard let markups = byPage[pageIndex] else { return nil }
        return markups.last { markup in
            if let marker = markup.noteMarkerRect, marker.insetBy(dx: -3, dy: -3).contains(point) { return true }
            return markup.quads.contains { $0.contains(point) }
        }
    }

    private func redraw() {
        guard let pdfView else { return }
        // PDFKit hosts pages in an internal document view and caches their
        // rendering; invalidating the whole subtree forces `OverlayPDFPage.draw`
        // to re-run for visible pages so live edits show without a scroll.
        pdfView.needsDisplay = true
        invalidate(pdfView)
    }

    private func invalidate(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews {
            invalidate(subview)
        }
    }
}
