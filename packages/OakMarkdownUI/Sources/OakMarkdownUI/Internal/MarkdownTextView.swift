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
    /// Width (`NSNumber`) of that bar.
    static let blockquoteBarWidth = NSAttributedString.Key("OakMarkdownBlockquoteBarWidth")
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
                let barWidth = (storage.attribute(.blockquoteBarWidth, at: range.location,
                                                  effectiveRange: nil) as? NSNumber)
                    .map { CGFloat($0.doubleValue) } ?? 3
                // With no fill the bar is the quote's edge, so it sits flush left.
                let hasFill = fill.alphaComponent > 0
                let barRect = CGRect(x: hasFill ? fillRect.minX + 4 : origin.x,
                                     y: fillRect.minY + 3,
                                     width: barWidth, height: fillRect.height - 6)
                bar.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
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
        revealLink?.invalidate()
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
            if !fadesAppendedText { drainReveal() }
        }
    }

    // MARK: - Streaming reveal
    //
    // ChatGPT's native app (`OAIMarkdown.TextFadeAnimator`, read from the shipped
    // 1.2026.183 binary) is the reference. Its fields say how it works, and three
    // things from it are taken here:
    //
    //   - The clock is a display link (`ClosureDisplayLink`, `frameRate`,
    //     `minimumFrameRate`), not a timer. A 60 Hz `Timer` drifts against vsync and
    //     drops or doubles frames on a 120 Hz display; that beat is visible in a fade.
    //   - The unit is a moving front over the characters (`insertionPartsByID`,
    //     `lastFadedPartEndLocation`, `advanceBy`, `advanceDuration`), not a line.
    //     Each slice the front passes fades on its own clock, so the leading edge is
    //     a gradient as wide as `rate × fadeDuration` characters and it runs straight
    //     on from one line to the next. A line sweep restarts at every wrap, and a
    //     line that grows while it sweeps reveals in two pieces.
    //   - Opacity is quantised (`lastAppliedRenderingUpdateBucket`; the binary
    //     multiplies progress by 24 and rounds). A run is rewritten only when its
    //     step changes, so a frame costs a handful of attribute writes at most.
    //
    // The front speeds up with the backlog (`flushDurationThreshold`,
    // `flushMultiplier` in the reference). It works to a deadline: text is reached
    // within `targetDrain` of arriving, so a burst drains at an even pace and ends
    // on time, where a rate proportional to the backlog would slow as the backlog
    // shrank and crawl at the end. With no deadline pressing it moves at `baseRate`.
    //
    // Temporary attributes, not a layer mask, stay the mechanism: the worst a bug
    // here can do is leave a run dim, never invisible.

    /// One slice the front has passed, fading on its own clock.
    private struct FadeRun {
        var range: NSRange
        let start: CFTimeInterval
        /// Last opacity step written, in 0...`fadeSteps`.
        var step: Int
    }

    /// One slice goes from clear to full in this.
    private static let fadeDuration: CFTimeInterval = 0.32
    /// Slowest the front moves while it has text to reveal, in characters per second.
    private static let baseRate: Double = 140
    /// The front never trails the arrived text by more than this.
    private static let targetDrain: CFTimeInterval = 0.45
    /// Stream ended with a backlog: finish within this instead of snapping.
    private static let drainTarget: CFTimeInterval = 0.25
    /// Opacity steps per fade.
    private static let fadeSteps = 24

    private var fadeRuns: [FadeRun] = []
    /// Characters before this have started fading or were never hidden.
    private var revealFront = 0
    /// End of the text waiting for the front.
    private var revealEnd = 0
    /// Fractional characters the front has earned but not yet taken.
    private var frontCarry: Double = 0
    private var lastRevealTick: CFTimeInterval?
    private var revealLink: CADisplayLink?
    /// When the front must have reached `revealEnd`.
    private var revealDeadline: CFTimeInterval = 0

    /// The reveal's clock. Tests replace it to drive frames without a display:
    /// a display link stops while the screen is locked or the window hidden.
    var revealClock: () -> CFTimeInterval = { CACurrentMediaTime() }

    private var hasPendingReveal: Bool { revealFront < revealEnd || !fadeRuns.isEmpty }

    /// Hide a freshly-appended character range until the front reaches it. Applies
    /// alpha 0 synchronously so nothing flashes at full opacity first.
    func fadeInAppendedText(_ range: NSRange) {
        guard fadesAppendedText, range.length > 0, let lm = layoutManager else { return }
        // The streamed tail can be rewritten (markdown reflow moves the divergence
        // point back). Restore any overlapping run still in flight to full opacity
        // BEFORE dropping it — otherwise a run only partly covered stays dim.
        for run in fadeRuns where NSIntersectionRange(run.range, range).length > 0 {
            clearFadeAlpha(run.range, lm: lm)
        }
        fadeRuns.removeAll { NSIntersectionRange($0.range, range).length > 0 }

        applyFadeAlpha(0, to: range, lm: lm)
        if revealFront >= revealEnd {
            revealFront = range.location
            revealEnd = range.upperBound
        } else {
            revealFront = min(revealFront, range.location)
            revealEnd = max(revealEnd, range.upperBound)
        }
        revealDeadline = revealClock() + Self.targetDrain
        startRevealLink()
    }

    /// Snap any reveal that begins before `location` to full opacity and drop it.
    /// Called when the streamed tail was rewritten (markdown reflow restyled text
    /// already on screen): those ranges are stale, and continuing to drive alpha
    /// over them re-dims what the reader has already read.
    func finalizeFades(before location: Int) {
        guard let lm = layoutManager else { return }
        var remaining: [FadeRun] = []
        for run in fadeRuns {
            if run.range.location < location {
                clearFadeAlpha(run.range, lm: lm)
            } else {
                remaining.append(run)
            }
        }
        fadeRuns = remaining
        // Text between the front and `location` is still hidden where the rewrite
        // did not reach it. Show it, so nothing before `location` stays clear.
        if revealFront < location {
            clearFadeAlpha(NSRange(location: revealFront, length: location - revealFront), lm: lm)
            revealFront = location
            revealEnd = max(revealEnd, location)
            frontCarry = 0
        }
        if !hasPendingReveal { stopRevealLink() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A display link follows the window's screen, so it is made per window.
        // Off-window there is nothing to watch: settle at full opacity.
        stopRevealLink()
        if window == nil {
            finishAllFades()
        } else if hasPendingReveal {
            startRevealLink()
        }
    }

    private func startRevealLink() {
        guard revealLink == nil, window != nil else { return }
        let link = displayLink(target: RevealLinkTarget(self), selector: #selector(RevealLinkTarget.step(_:)))
        // .common so the reveal keeps running during scroll and event tracking
        // instead of freezing mid-fade.
        link.add(to: .main, forMode: .common)
        revealLink = link
        lastRevealTick = nil
    }

    func tickReveal() {
        guard let lm = layoutManager, let storage = textStorage else { stopRevealLink(); return }
        let now = revealClock()
        let dt = min(max(now - (lastRevealTick ?? now), 0), 0.1)
        lastRevealTick = now

        // Advance the front.
        revealEnd = min(revealEnd, storage.length)
        revealFront = min(revealFront, revealEnd)
        let backlog = revealEnd - revealFront
        if backlog > 0 {
            let remaining = max(revealDeadline - now, 1.0 / 120.0)
            frontCarry += max(Self.baseRate, Double(backlog) / remaining) * dt
            let taken = min(Int(frontCarry), backlog)
            if taken > 0 {
                frontCarry -= Double(taken)
                fadeRuns.append(FadeRun(range: NSRange(location: revealFront, length: taken),
                                        start: now, step: 0))
                revealFront += taken
            }
        } else {
            frontCarry = 0
        }

        // Fade what it has passed. Write only when a run's step changes.
        var stillFading: [FadeRun] = []
        for var run in fadeRuns {
            let progress = (now - run.start) / Self.fadeDuration
            if progress >= 1 {
                clearFadeAlpha(run.range, lm: lm)
                continue
            }
            let eased = progress * progress * (3 - 2 * progress)
            let step = Int((eased * Double(Self.fadeSteps)).rounded())
            if step != run.step {
                applyFadeAlpha(CGFloat(step) / CGFloat(Self.fadeSteps), to: run.range, lm: lm)
                run.step = step
            }
            stillFading.append(run)
        }
        fadeRuns = stillFading
        if showsTypingDot { updateTypingDot() }
        if !hasPendingReveal { stopRevealLink() }
    }

    /// Stream ended. Anything still hidden finishes at the drain pace rather than
    /// snapping, so the last paragraph lands the way the rest of it did.
    private func drainReveal() {
        guard hasPendingReveal, window != nil else {
            finishAllFades()
            return
        }
        revealDeadline = min(revealDeadline, revealClock() + Self.drainTarget)
        startRevealLink()
    }

    private func finishAllFades() {
        // Belt-and-suspenders: clear the overlay across the WHOLE text, not just
        // tracked ranges, so no run can ever be left dim once the stream settles.
        if let lm = layoutManager, let storage = textStorage, storage.length > 0 {
            lm.removeTemporaryAttribute(.foregroundColor,
                                        forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        fadeRuns.removeAll()
        revealFront = revealEnd
        stopRevealLink()
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

    private func stopRevealLink() {
        revealLink?.invalidate()
        revealLink = nil
        lastRevealTick = nil
        frontCarry = 0
    }

    // MARK: - Typing dot

    /// Show ChatGPT's breathing dot after the last revealed character. Only the
    /// trailing block of a streaming answer sets this.
    var showsTypingDot = false {
        didSet { if showsTypingDot != oldValue { updateTypingDot() } }
    }
    private var typingDotLayer: CALayer?

    /// Place the dot after the reveal front — not after text that is still
    /// hidden, which would leave it floating ahead of the words.
    func updateTypingDot() {
        guard showsTypingDot, let lm = layoutManager, let container = textContainer,
              let storage = textStorage else {
            typingDotLayer?.removeFromSuperlayer()
            typingDotLayer = nil
            return
        }
        wantsLayer = true
        let dot: CALayer
        if let existing = typingDotLayer {
            dot = existing
        } else {
            dot = CALayer()
            layer?.addSublayer(dot)
            TypingDot.animate(dot)
            typingDotLayer = dot
        }

        let end = min(hasPendingReveal ? revealFront : storage.length, storage.length)
        let font = (end > 0 ? storage.attribute(.font, at: end - 1, effectiveRange: nil) as? NSFont : nil)
            ?? self.font ?? .systemFont(ofSize: 14)
        let size = (font.pointSize * 0.62).rounded()
        var center = CGPoint(x: size / 2, y: font.ascender - font.xHeight / 2)
        if end > 0 {
            let glyph = lm.glyphIndexForCharacter(at: end - 1)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let baseline = line.minY + lm.location(forGlyphAt: glyph).y
            // Sits on the x-height, a letter-space after the last glyph.
            center = CGPoint(x: glyphRect.maxX + size * 0.75, y: baseline - font.xHeight / 2)
        }
        let origin = textContainerOrigin
        let x = min(center.x + origin.x, bounds.width - size / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = (self.textColor ?? .labelColor).cgColor
        }
        dot.cornerRadius = size / 2
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.position = CGPoint(x: x, y: center.y + origin.y)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        if showsTypingDot { updateTypingDot() }
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

/// Display-link target that does not keep its text view alive: a display link
/// retains its target until invalidated.
private final class RevealLinkTarget: NSObject {
    private weak var owner: MarkdownTextView?

    init(_ owner: MarkdownTextView) {
        self.owner = owner
    }

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.tickReveal()
        }
    }
}
