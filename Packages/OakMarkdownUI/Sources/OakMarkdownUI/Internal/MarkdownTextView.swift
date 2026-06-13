import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks an inline-code run so `HuggingLayoutManager` draws it as a padded
    /// rounded pill rather than a bare selection-style rect.
    static let inlineCodePill = NSAttributedString.Key("OakMarkdownInlineCodePill")
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
    /// Host-supplied preview content for a link URL (see `ProseBlockView.linkPreview`).
    var linkPreview: ((URL) -> AnyView?)?

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
        guard let url = linkURL(in: storage, at: charIndex, effectiveRange: &range),
              preview(url) != nil else { cancelHover(); return }

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
            self?.showPreview(url: url, anchorRect: anchorRect)
        }
    }

    private func showPreview(url: URL, anchorRect: NSRect) {
        guard let content = linkPreview?(url), window != nil else { return }
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
