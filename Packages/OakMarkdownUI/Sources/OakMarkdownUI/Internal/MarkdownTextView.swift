import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks an inline-code run so `HuggingLayoutManager` draws it as a padded
    /// rounded pill rather than a bare selection-style rect.
    static let inlineCodePill = NSAttributedString.Key("OakMarkdownInlineCodePill")
    /// Fill color (`NSColor`) for a block-quote range — drawn as a rounded background.
    static let blockquoteFill = NSAttributedString.Key("OakMarkdownBlockquoteFill")
    /// Bar color (`NSColor`) for a block-quote range — drawn as a left vertical accent.
    static let blockquoteBar = NSAttributedString.Key("OakMarkdownBlockquoteBar")
}

enum MarkdownInlineCodePill {
    /// Points the pill background extends past the code glyphs on each side. The
    /// builder kerns the neighboring characters by the same amount so the overshoot
    /// no longer eats the space between a code span and its surrounding words.
    static let horizontalPadding: CGFloat = 4.5
}

/// Draws inline-code spans as rounded pills that hug the glyph height, while leaving
/// everything else (notably the text selection) to the default drawing so multi-line
/// selection stays continuous.
///
/// `.backgroundColor` runs and the selection both funnel through
/// `fillBackgroundRectArray`. We only intercept runs tagged `.inlineCodePill`; for
/// those we draw a rounded rect sized to the font's ascent/descent and placed off the
/// real text baseline (the line-fragment center is unreliable under `lineHeightMultiple`).
final class HuggingLayoutManager: NSLayoutManager {
    /// Paint block-quote decorations (rounded fill + left bar) behind the glyphs and
    /// behind the selection highlight — so the quote reads as a contained block.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawBlockquotes(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawBlockquotes(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0,
              let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.blockquoteFill, in: charRange, options: []) { value, range, _ in
            guard let fill = value as? NSColor, range.length > 0 else { return }
            let bar = storage.attribute(.blockquoteBar, at: range.location, effectiveRange: nil) as? NSColor

            // Union the line fragments the quote occupies into one box.
            let glyphRange = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                box = box.isNull ? rect : box.union(rect)
            }
            guard !box.isNull else { return }

            let sideInset: CGFloat = 2
            let vPad: CGFloat = 4
            let width = max(container.size.width - sideInset * 2, 0)
            let fillRect = CGRect(x: sideInset, y: box.minY - vPad,
                                  width: width, height: box.height + vPad * 2)
                .offsetBy(dx: origin.x, dy: origin.y)

            fill.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 5, yRadius: 5).fill()

            if let bar {
                let barRect = CGRect(x: fillRect.minX + 4, y: fillRect.minY + 3,
                                     width: 3, height: fillRect.height - 6)
                bar.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        guard let storage = textStorage, storage.length > 0,
              let container = textContainers.first,
              let font = pillFont(at: charRange, in: storage) else {
            super.fillBackgroundRectArray(rectArray, count: rectCount,
                                          forCharacterRange: charRange, color: color)
            return
        }

        let padding: CGFloat = 1.5
        let expand = MarkdownInlineCodePill.horizontalPadding
        // ascender is positive, descender negative → full glyph extent around the baseline.
        let height = ceil(font.ascender - font.descender) + padding * 2

        color.set()
        for i in 0..<rectCount {
            let r = rectArray[i]
            guard r.width > 0 else { continue }
            let glyph = glyphIndex(for: CGPoint(x: r.minX + 1, y: r.midY), in: container)
            let baselineY = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                + location(forGlyphAt: glyph).y
            let left = max(r.minX - expand, 0)
            let pill = NSRect(x: left,
                              y: (baselineY - font.ascender - padding).rounded(),
                              width: r.maxX + expand - left,
                              height: height)
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        }
    }

    /// The code font for an inline-code run, or nil if `charRange` isn't tagged as a pill.
    private func pillFont(at charRange: NSRange, in storage: NSTextStorage) -> NSFont? {
        let index = min(max(charRange.location, 0), storage.length - 1)
        guard storage.attribute(.inlineCodePill, at: index, effectiveRange: nil) != nil else { return nil }
        return (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }
}

/// Non-editable prose text view that clears its selection when it stops being the
/// first responder. Each prose block is its own text view; without this, selecting
/// in one block and clicking elsewhere leaves the old highlight stuck on screen
/// until some later redraw clears it.
///
/// It also drives the rich link-hover preview: when the cursor dwells on a link that
/// `linkPreview` recognizes, it shows the supplied SwiftUI view in a popover anchored to
/// the link's glyphs (the default raw-URL tooltip is suppressed by the coordinator).
final class MarkdownTextView: NSTextView {
    /// Host-supplied preview content for a link, given its URL and visible label text
    /// (see `ProseBlockView.linkPreview`).
    var linkPreview: ((URL, String) -> AnyView?)?

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverPopover: NSPopover?
    private var hoveredLinkRange: NSRange?
    private var hoverTimer: Timer?

    /// Dwell before the preview appears — long enough to ignore a cursor passing through.
    private let hoverDelay: TimeInterval = 0.35

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        return resigned
    }

    deinit {
        hoverTimer?.invalidate()
        hoverPopover?.close()
    }

    // MARK: - Sizing

    /// SwiftUI drives this view's size through `ProseBlockView.sizeThatFits`. Report no
    /// intrinsic size so AppKit's *natural* (unwrapped, single-line) text width can never
    /// leak back as the view's own width — which would balloon the bubble past a narrow
    /// chat panel and clip the text. The height likewise comes from `sizeThatFits`.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// A second layout stack that shares the display stack's `NSTextStorage` but is never
    /// drawn. `sizeThatFits` measures height through THIS container so it never mutates the
    /// *display* container's wrap width. That decouples measurement from display: a wide
    /// measurement probe can no longer leak into the rendered view and stick after a
    /// streamed answer settles (the "settle-clip" bug). The display container's width is
    /// governed solely by `widthTracksTextView`, which pins it to the committed frame.
    ///
    /// Layout is lazy, so the secondary stack only does work when `measuredHeight` runs —
    /// text edits merely invalidate it; they don't force a redundant relayout.
    private lazy var measuringContainer: NSTextContainer = {
        let container = NSTextContainer(size: CGSize(width: CGFloat(0), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let lm = NSLayoutManager()
        lm.addTextContainer(container)
        textStorage?.addLayoutManager(lm)
        return container
    }()

    /// Height the text needs when wrapped at `width`, measured without touching the display
    /// container (so a probe width can never become the rendered wrap width).
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard let lm = measuringContainer.layoutManager else { return 0 }
        measuringContainer.size = CGSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: measuringContainer)
        return ceil(lm.usedRect(for: measuringContainer).height)
    }

    /// The *minimum* width the text can occupy — the widest unbreakable run (longest word;
    /// for CJK, a single character). Reported as the view's size for ambiguous proposals
    /// (SwiftUI's `nil` ideal / `.infinity` max probes) so this view behaves like a flexible
    /// `Text`: it never demands a fixed default width that could exceed a narrow panel, and
    /// the surrounding `.frame(maxWidth: .infinity)` is what makes it fill the column.
    func minimumContentWidth() -> CGFloat {
        guard let lm = measuringContainer.layoutManager else { return 0 }
        measuringContainer.size = CGSize(width: CGFloat(1), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: measuringContainer)
        return ceil(lm.usedRect(for: measuringContainer).width)
    }

    // MARK: - Link hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cancelHover()
    }

    override func mouseDown(with event: NSEvent) {
        // Dismiss first so the click lands on the link (citation navigation) cleanly.
        cancelHover()
        super.mouseDown(with: event)
    }

    private func handleHover(at point: NSPoint) {
        guard let preview = linkPreview,
              let lm = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { cancelHover(); return }

        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard lm.usedRect(for: container).contains(local) else { cancelHover(); return }

        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: local, in: container,
                                       fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { cancelHover(); return }

        var range = NSRange(location: 0, length: 0)
        guard let url = linkURL(in: storage, at: charIndex, effectiveRange: &range)
        else { cancelHover(); return }
        let label = storage.attributedSubstring(from: range).string
        guard preview(url, label) != nil else { cancelHover(); return }

        // `glyphIndex(for:)` returns the *nearest* glyph, so confirm the point really
        // lands on the link's glyphs before showing anything.
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let linkRect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        guard linkRect.contains(local) else { cancelHover(); return }

        if hoveredLinkRange == range { return }  // already shown or scheduled for this link

        cancelHover()
        hoveredLinkRange = range
        let anchorRect = linkRect.offsetBy(dx: origin.x, dy: origin.y)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) {
            [weak self] _ in
            self?.showPreview(url: url, label: label, anchorRect: anchorRect)
        }
    }

    private func showPreview(url: URL, label: String, anchorRect: NSRect) {
        guard let content = linkPreview?(url, label), window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .applicationDefined  // we control dismissal via hover tracking
        popover.animates = true
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Flipped text view → the link's maxY edge is its visual bottom, so the card
        // drops just below the citation.
        popover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
        hoverPopover = popover
    }

    private func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoveredLinkRange = nil
        if hoverPopover?.isShown == true { hoverPopover?.close() }
        hoverPopover = nil
    }

    private func linkURL(in storage: NSTextStorage, at index: Int,
                         effectiveRange: inout NSRange) -> URL? {
        guard let value = storage.attribute(.link, at: index, effectiveRange: &effectiveRange)
        else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}
