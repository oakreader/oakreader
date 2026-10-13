import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks an inline-code run so `HuggingLayoutManager` draws it as a padded
    /// rounded pill rather than a bare selection-style rect.
    static let inlineCodePill = NSAttributedString.Key("OakMarkdownInlineCodePill")
    /// Hairline color (`NSColor`) stroked around an inline-code pill. Dia's
    /// `InlineCodeProperties.strokeColor`: on a tinted message background the fill
    /// alone disappears, and the stroke is what keeps the pill legible.
    static let inlineCodeStroke = NSAttributedString.Key("OakMarkdownInlineCodeStroke")
    /// Corner radius (`NSNumber`) of that pill.
    static let inlineCodeRadius = NSAttributedString.Key("OakMarkdownInlineCodeRadius")
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
              let style = pillStyle(at: charRange, in: storage) else {
            super.fillBackgroundRectArray(rectArray, count: rectCount,
                                          forCharacterRange: charRange, color: color)
            return
        }

        let font = style.font
        // ascender is positive, descender negative → full glyph extent around the baseline.
        let height = ceil(font.ascender - font.descender) + style.verticalPadding * 2

        color.set()
        for i in 0..<rectCount {
            let r = rectArray[i]
            guard r.width > 0 else { continue }
            let glyph = glyphIndex(for: CGPoint(x: r.minX + 1, y: r.midY), in: container)
            let baselineY = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                + location(forGlyphAt: glyph).y
            let left = max(r.minX - style.expand, 0)
            let pill = NSRect(x: left,
                              y: (baselineY - font.ascender - style.verticalPadding).rounded(),
                              width: r.maxX + style.expand - left,
                              height: height)
            // A nil radius means capsule — the citation chip stays fully rounded at any
            // font size, where a fixed radius would read as a rectangle on a tall line.
            let radius = style.cornerRadius ?? height / 2
            let path = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
            path.fill()
            if let stroke = style.stroke {
                // Inset by half the line width so the hairline sits inside the fill
                // rather than straddling its edge and reading as two pixels.
                let inset = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5),
                                         xRadius: max(radius - 0.5, 0),
                                         yRadius: max(radius - 0.5, 0))
                stroke.setStroke()
                inset.lineWidth = 1
                inset.stroke()
                color.set()   // restore the fill colour for the next rect
            }
        }
    }

    /// Geometry for a pill-drawn run — inline code. `nil` when
    /// `charRange` is an ordinary `.backgroundColor` run (or the selection), which must
    /// keep AppKit's default square fill so multi-line selection stays continuous.
    private struct PillStyle {
        let font: NSFont
        let expand: CGFloat
        let verticalPadding: CGFloat
        /// `nil` → capsule (radius derived from the drawn height).
        let cornerRadius: CGFloat?
        /// `nil` → fill only.
        let stroke: NSColor?
    }

    private func pillStyle(at charRange: NSRange, in storage: NSTextStorage) -> PillStyle? {
        let index = min(max(charRange.location, 0), storage.length - 1)
        func font(_ fallback: NSFont) -> NSFont {
            (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? fallback
        }
        if storage.attribute(.inlineCodePill, at: index, effectiveRange: nil) != nil {
            let stroke = storage.attribute(.inlineCodeStroke, at: index, effectiveRange: nil) as? NSColor
            let radius = storage.attribute(.inlineCodeRadius, at: index, effectiveRange: nil) as? NSNumber
            return PillStyle(font: font(.monospacedSystemFont(ofSize: 13, weight: .regular)),
                             expand: MarkdownInlineCodePill.horizontalPadding,
                             verticalPadding: 1.5,
                             cornerRadius: radius.map { CGFloat($0.doubleValue) } ?? 4,
                             stroke: (stroke?.alphaComponent ?? 0) > 0 ? stroke : nil)
        }
        return nil
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
    /// The link the pointer is over, underline-wise. Tracked apart from
    /// `hoveredLinkRange` because that one only exists when a preview is on offer,
    /// and every link should answer the pointer whether or not it has a card.
    private var underlinedLinkRange: NSRange?

    /// Colour of a link's underline while the pointer is on it. Dia keeps hover
    /// underline style and colour in `SupertabTextView.LinkAttributes`, separate
    /// from the resting ones: the link answers the pointer without the text itself
    /// changing colour, which would reflow nothing but still read as a flicker.
    var linkHoverUnderlineColor: NSColor?
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
        revealTimer?.invalidate()
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

    // MARK: - Streaming fade-in

    /// When true, character ranges handed to `fadeInAppendedText(_:)` are revealed
    /// instead of appearing instantly. Set false to finish any reveal still in
    /// flight at full opacity (stream ended / reduce-motion).
    var fadesAppendedText = false {
        didSet {
            if fadesAppendedText { isDraining = false } else { drainReveal() }
        }
    }

    // MARK: - Streaming reveal
    //
    // Dia's `AssistantUI.TextFadeAnimator` is the reference, and the thing worth
    // taking from it is not the fade — it is the UNIT and the CADENCE. It reveals
    // *line fragments*, each one scheduled off the previous (`nextLineTask`,
    // `lineIntervalMultiplier`), with a cap on how long the trailing line may wait
    // (`trailingLineRevealMaxDelay`). The text therefore arrives at a typographic
    // rhythm rather than at the network's rhythm.
    //
    // Fading a whole delta as one block — what this did before — ties the reveal to
    // chunk boundaries: a 300-character burst lights up at once, a 5-character one
    // barely registers, and the answer pulses unevenly because the provider's
    // packets are uneven. Lines are the unit a reader actually consumes.
    //
    // Two departures from Dia, both deliberate:
    //
    //   - The interval is derived from the backlog instead of being a constant with
    //     a delay cap. Dia needs `trailingLineRevealMaxDelay` precisely because a
    //     fixed cadence falls behind a fast stream; targeting a drain time instead
    //     means the reveal relaxes to a reading pace when the model is slow and
    //     accelerates when it is ahead, without ever snapping.
    //   - A line is swept head-to-tail with a soft edge rather than cross-faded,
    //     which is what Dia's per-line `CAGradientLayer` buys. Doing it with
    //     temporary attributes keeps the mechanism unable to hide text: the worst
    //     a bug here can do is leave a run dim, never invisible, which a CALayer
    //     mask over the whole text view cannot promise.

    /// One line fragment waiting for, or in, its reveal.
    private struct RevealLine {
        let range: NSRange
        /// Uptime when the sweep began; nil while queued.
        var start: TimeInterval?
        /// Uptime when it was enqueued, for the starvation cap.
        let queuedAt: TimeInterval
    }

    /// One line's sweep, head to tail.
    private static let lineDuration: TimeInterval = 0.26
    /// Share of `lineDuration` spent travelling; the rest is the edge's own fade,
    /// so the leading edge stays soft instead of arriving as a hard wipe.
    private static let sweepShare: Double = 0.6
    /// Lines allowed to sweep at once. More than this and the page shimmers.
    private static let maxConcurrentLines = 3
    /// Backlog drains within this, however deep it is.
    private static let targetDrain: TimeInterval = 0.45
    /// Floor: a line never waits longer than this, whatever the scheduler thinks.
    private static let maxQueueWait: TimeInterval = 1.0

    private var revealLines: [RevealLine] = []
    private var nextLineStart: TimeInterval = 0
    private var revealTimer: Timer?
    /// Stream ended with a backlog: drain at the fastest cadence rather than snap.
    private var isDraining = false

    /// Reveal a freshly-appended character range. Applies alpha 0 synchronously so
    /// nothing flashes at full opacity before its turn comes.
    func fadeInAppendedText(_ range: NSRange) {
        guard fadesAppendedText, range.length > 0, let lm = layoutManager else { return }
        // The streamed tail can be rewritten (markdown reflow moves the divergence
        // point back). Restore any overlapping line still in flight to full opacity
        // BEFORE dropping it — otherwise a run only partially covered by the new
        // range stays dim forever.
        for line in revealLines where NSIntersectionRange(line.range, range).length > 0 {
            clearFadeAlpha(line.range, lm: lm)
        }
        revealLines.removeAll { NSIntersectionRange($0.range, range).length > 0 }

        let now = ProcessInfo.processInfo.systemUptime
        applyFadeAlpha(0, to: range, lm: lm)
        for lineRange in lineFragmentRanges(in: range) {
            revealLines.append(RevealLine(range: lineRange, start: nil, queuedAt: now))
        }
        startRevealTimer()
    }

    /// Snap any reveal that begins before `location` to full opacity and drop it.
    /// Called when the streamed tail was rewritten (markdown reflow restyled text
    /// already on screen): those ranges are stale, and continuing to drive alpha
    /// over them re-dims what the reader has already read.
    func finalizeFades(before location: Int) {
        guard let lm = layoutManager else { return }
        var remaining: [RevealLine] = []
        for line in revealLines {
            if line.range.location < location {
                clearFadeAlpha(line.range, lm: lm)
            } else {
                remaining.append(line)
            }
        }
        revealLines = remaining
        if revealLines.isEmpty { stopRevealTimer() }
    }

    /// Split a character range along its laid-out line fragments. Falls back to the
    /// whole range when layout cannot answer — a reveal that is too coarse beats a
    /// run that never reveals.
    private func lineFragmentRanges(in range: NSRange) -> [NSRange] {
        guard let lm = layoutManager, let container = textContainer else { return [range] }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return [range] }
        var out: [NSRange] = []
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
            let overlap = NSIntersectionRange(lineGlyphRange, glyphRange)
            guard overlap.length > 0 else { return }
            out.append(lm.characterRange(forGlyphRange: overlap, actualGlyphRange: nil))
        }
        _ = container
        return out.isEmpty ? [range] : out
    }

    /// Seconds between two line starts. Shorter the deeper the backlog, so a bursty
    /// stream catches up without the reveal ever outrunning what has arrived.
    private func lineInterval(queued: Int) -> TimeInterval {
        if isDraining { return 0.03 }
        return min(0.15, max(0.035, Self.targetDrain / Double(max(1, queued))))
    }

    private func startRevealTimer() {
        guard revealTimer == nil else { return }
        // .common so the reveal keeps running during scroll and event tracking
        // instead of freezing mid-sweep.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickReveal()
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func tickReveal() {
        guard let lm = layoutManager else { stopRevealTimer(); return }
        let now = ProcessInfo.processInfo.systemUptime

        // Start whatever is due.
        var running = revealLines.reduce(into: 0) { if $1.start != nil { $0 += 1 } }
        for index in revealLines.indices where revealLines[index].start == nil {
            let starved = now - revealLines[index].queuedAt >= Self.maxQueueWait
            guard starved || (running < Self.maxConcurrentLines && now >= nextLineStart) else { break }
            revealLines[index].start = now
            running += 1
            let queued = revealLines.reduce(into: 0) { if $1.start == nil { $0 += 1 } }
            nextLineStart = now + lineInterval(queued: queued)
        }

        // Advance the ones running.
        var stillActive: [RevealLine] = []
        for line in revealLines {
            guard let start = line.start else {
                stillActive.append(line)
                continue
            }
            let progress = (now - start) / Self.lineDuration
            if progress >= 1 {
                clearFadeAlpha(line.range, lm: lm)
            } else {
                applySweep(progress, to: line.range, lm: lm)
                stillActive.append(line)
            }
        }
        revealLines = stillActive
        if revealLines.isEmpty { stopRevealTimer() }
    }

    /// Sweep one line head to tail. The line is quantised into segments, each with
    /// its own delayed fade, which is a soft-edged wipe at a bounded cost: a handful
    /// of temporary-attribute writes per line per frame, not one per glyph.
    private func applySweep(_ progress: Double, to range: NSRange, lm: NSLayoutManager) {
        let segments = max(1, min(12, range.length / 3))
        let travel = Self.sweepShare
        let edge = 1 - travel
        for index in 0..<segments {
            let offset = travel * Double(index) / Double(segments)
            let local = max(0, min(1, (progress - offset) / edge))
            let eased = local * local * (3 - 2 * local)
            let location = range.location + range.length * index / segments
            let next = range.location + range.length * (index + 1) / segments
            applyFadeAlpha(eased, to: NSRange(location: location, length: next - location), lm: lm)
        }
    }

    /// Stream ended. Anything still queued finishes at the fastest cadence rather
    /// than snapping, so the last paragraph lands the way the rest of it did.
    private func drainReveal() {
        guard !revealLines.isEmpty else {
            finishAllFades()
            return
        }
        isDraining = true
        startRevealTimer()
    }

    private func finishAllFades() {
        // Belt-and-suspenders: clear the overlay across the WHOLE text, not just
        // tracked ranges, so no run can ever be left dim once the stream settles.
        if let lm = layoutManager, let storage = textStorage, storage.length > 0 {
            lm.removeTemporaryAttribute(.foregroundColor,
                                        forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        revealLines.removeAll()
        stopRevealTimer()
    }

    /// Overlay a temporary foreground color at `alpha`, preserving each run's real color
    /// (links, code spans). Temporary attributes don't trigger relayout, so this is cheap.
    private func applyFadeAlpha(_ alpha: CGFloat, to range: NSRange, lm: NSLayoutManager) {
        guard let storage = textStorage else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        storage.enumerateAttribute(.foregroundColor, in: clamped, options: []) { value, sub, _ in
            let base = (value as? NSColor) ?? self.textColor ?? .labelColor
            lm.addTemporaryAttribute(.foregroundColor, value: base.withAlphaComponent(alpha),
                                     forCharacterRange: sub)
        }
    }

    private func clearFadeAlpha(_ range: NSRange, lm: NSLayoutManager) {
        guard let storage = textStorage else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clamped)
    }

    private func stopRevealTimer() {
        revealTimer?.invalidate()
        revealTimer = nil
        isDraining = false
        nextLineStart = 0
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
        guard let lm = layoutManager, let container = textContainer,
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

        // `glyphIndex(for:)` returns the *nearest* glyph, so confirm the point really
        // lands on the link's glyphs before reacting at all.
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let linkRect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        guard linkRect.contains(local) else { cancelHover(); return }

        underlineHoveredLink(range)

        // Only a link with something to show opens a card.
        guard let preview = linkPreview, preview(url, label) != nil else {
            cancelPreview()
            return
        }
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
        clearHoverUnderline()
        cancelPreview()
    }

    private func cancelPreview() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoveredLinkRange = nil
        if hoverPopover?.isShown == true { hoverPopover?.close() }
        hoverPopover = nil
    }

    /// Thicken and recolour the hovered link's underline. A temporary attribute, so
    /// it costs no relayout and cannot survive into the stored text.
    private func underlineHoveredLink(_ range: NSRange) {
        guard let color = linkHoverUnderlineColor, let lm = layoutManager else { return }
        guard underlinedLinkRange != range else { return }
        clearHoverUnderline()
        lm.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle([.single, .thick]).rawValue,
            .underlineColor: color,
        ], forCharacterRange: range)
        underlinedLinkRange = range
    }

    private func clearHoverUnderline() {
        guard let range = underlinedLinkRange, let lm = layoutManager,
              let storage = textStorage else {
            underlinedLinkRange = nil
            return
        }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        if clamped.length > 0 {
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: clamped)
            lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: clamped)
        }
        underlinedLinkRange = nil
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
