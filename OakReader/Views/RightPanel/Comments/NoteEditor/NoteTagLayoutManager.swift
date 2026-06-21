import AppKit

// MARK: - Layout manager (#tag chips, block decorations, inline math)

/// Custom `NSLayoutManager` that paints what plain attributes can't: rounded
/// `#tag` chips, continuous block backgrounds (quote fill + rule, code fill), and
/// inline math images. All decoration reads already-laid-out geometry so it never
/// forces a re-layout during drawing.
final class NoteTagLayoutManager: NSLayoutManager {
    private struct BlockSurfaceMetrics {
        let sideInset: CGFloat
        let verticalPadding: CGFloat
        let radius: CGFloat
    }

    private func surfaceMetrics(for block: NoteBlock) -> BlockSurfaceMetrics? {
        switch block {
        case .quote:
            return BlockSurfaceMetrics(sideInset: 2, verticalPadding: 4, radius: 5)
        case .code:
            return BlockSurfaceMetrics(sideInset: 0, verticalPadding: 2, radius: 8)
        default:
            return nil
        }
    }

    private func blockSurfaceRect(_ block: NoteBlock, box: NSRect, fullWidth: CGFloat) -> NSRect? {
        guard let metrics = surfaceMetrics(for: block) else { return nil }
        return NSRect(
            x: metrics.sideInset,
            y: box.minY - metrics.verticalPadding,
            width: max(fullWidth - metrics.sideInset * 2, 0),
            height: box.height + metrics.verticalPadding * 2
        )
    }

    /// Visual quote/code bounds in text-container coordinates, used by height measurement.
    func blockDecorationBoundingRect() -> NSRect {
        var result = NSRect.null
        enumerateDecoratedBlockBoxes { block, box, fullWidth in
            guard let rect = blockSurfaceRect(block, box: box, fullWidth: fullWidth) else { return }
            result = result.union(rect)
        }
        return result
    }

    /// Paragraph-level decoration (quote fill + rule, code-block fill) belongs in
    /// the *background* pass — it runs before glyphs, is the API designed for
    /// backgrounds, and reads completed layout so it never forces a re-layout.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        enumerateDecoratedBlockBoxes { block, box, fullWidth in
            drawBlockSurface(block, box: box, fullWidth: fullWidth, origin: origin)
        }
    }

    private func enumerateDecoratedBlockBoxes(_ body: (NoteBlock, NSRect, CGFloat) -> Void) {
        guard let ts = textStorage, let container = textContainers.first else { return }
        let fullWidth = container.size.width
        let storageLen = ts.length
        guard storageLen > 0 else { return }

        // Paragraph decorations (quote fill + left rule; code-block fill) are drawn
        // here — the background pass — reading already-laid-out line fragments via
        // `enumerateLineFragments` (the idiomatic, layout-safe API; `boundingRect`
        // would force layout *during* drawing). A per-character `.backgroundColor`
        // attribute can't do these: it fills ragged, tight per-line rects with gaps
        // (a striped, broken look). One unioned rect reads as a single clean block.
        //
        // We walk block runs across the WHOLE text storage, NOT just `glyphsToShow`'s
        // character range: when a new line is added, AppKit redraws only the dirtied
        // slice, so scoping the fill to that slice truncated a multi-line code/quote
        // block to its old extent — the last line(s) fell outside the grey. Each run's
        // full `longestEffectiveRange` (newlines between same-block paragraphs carry the
        // attribute too, so the run is contiguous) always fills the entire block.
        var cursor = 0
        while cursor < storageLen {
            var runRange = NSRange(location: 0, length: 0)
            let value = ts.attribute(.oakBlock, at: cursor, longestEffectiveRange: &runRange,
                                     in: NSRange(location: 0, length: storageLen))
            cursor = NSMaxRange(runRange)
            guard let raw = value as? Int, let block = NoteBlock(rawValue: raw),
                  block == .quote || block == .code else { continue }
            let gr = glyphRange(forCharacterRange: runRange, actualCharacterRange: nil)
            var box = NSRect.null
            // `fragBox` is the full line-fragment union — the fallback for an EMPTY block
            // line that has no glyphs (so no used rect). Without it a just-toggled, still-
            // empty code block drew NO grey box, leaving only its paragraph spacing visible
            // as bare vertical margin (the "why is there just a gap?" bug).
            var fragBox = NSRect.null
            // Union the *used* rects (tight glyph box), NOT the full line-fragment rects:
            // the fragment also covers the paragraph's spacing-before/after, which would
            // pull that spacing INSIDE the fill (fat inner padding, the bug). Building from
            // the used rect keeps the grey tight to the text, so `paragraphSpacing*` lands
            // OUTSIDE the fill as real outer margin between the block and nearby lines.
            enumerateLineFragments(forGlyphRange: gr) { rect, usedRect, _, _, _ in
                box = box.union(usedRect)
                fragBox = fragBox.union(rect)
            }
            // A block you're still typing into can end on an empty (glyph-less) line —
            // the extra line fragment — which `enumerateLineFragments` skips. Fold it in
            // when the run reaches the end of the text so the current line stays filled.
            if NSMaxRange(runRange) >= storageLen {
                if !extraLineFragmentUsedRect.isEmpty { box = box.union(extraLineFragmentUsedRect) }
                if !extraLineFragmentRect.isEmpty { fragBox = fragBox.union(extraLineFragmentRect) }
            }
            // Empty block (no glyphs): fall back to the line fragment so it still shows a
            // box. One empty line has no content to look over-padded, so the fragment's
            // line height reads fine here.
            if (box.isNull || box.isEmpty), !fragBox.isNull, !fragBox.isEmpty {
                box = fragBox
            }
            guard !box.isNull, !box.isEmpty else { continue }
            // Pin the box's TOP to the line-fragment top, keeping its BOTTOM on the tight
            // used rect. `lineHeightMultiple` (1.15) is below the mono/body font's natural
            // line-height ratio, so the glyph used rect sticks out ABOVE its fragment
            // (negative minY relative to the fragment). Building the fill from that pushes
            // its rounded top above the editor's top inset, where the scroll view clips it
            // — the "clip appears only after I type the first character" bug (an empty block
            // draws from the fragment rect, so it's unaffected — hence empty looks fine).
            // code/quote carry no `paragraphSpacingBefore`, so the fragment top is the clean
            // paragraph top with no spacing folded in; only the bottom must stay on the used
            // rect so the trailing `paragraphSpacing` lands OUTSIDE the fill.
            if !fragBox.isNull, box.minY < fragBox.minY {
                box = NSRect(x: box.minX, y: fragBox.minY, width: box.width, height: box.maxY - fragBox.minY)
            }
            body(block, box, fullWidth)
        }
    }

    /// Paint one block surface. Drawing and measuring both go through `blockSurfaceRect`.
    func drawBlockSurface(_ block: NoteBlock, box: NSRect, fullWidth: CGFloat, origin: NSPoint) {
        guard let metrics = surfaceMetrics(for: block),
              let surface = blockSurfaceRect(block, box: box, fullWidth: fullWidth) else { return }
        let fill = surface.offsetBy(dx: origin.x, dy: origin.y)
        switch block {
        case .quote:
            NoteEditorStyle.quoteBackground.setFill()
            NSBezierPath(roundedRect: fill, xRadius: metrics.radius, yRadius: metrics.radius).fill()
        case .code:
            NoteEditorStyle.codeBlockBackground.setFill()
            NSBezierPath(roundedRect: fill, xRadius: metrics.radius, yRadius: metrics.radius).fill()
            let border = NSBezierPath(
                roundedRect: fill.insetBy(dx: 0.5, dy: 0.5),
                xRadius: metrics.radius,
                yRadius: metrics.radius
            )
            border.lineWidth = 1
            NoteEditorStyle.codeBlockBorder.setStroke()
            border.stroke()
        default:
            break
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let ts = textStorage, let container = textContainers.first {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

            // Inline `code` pills — a rounded, padded background that hugs the run,
            // mirroring the saved card's inline-code pill (the editor used to paint a
            // hard-edged `.backgroundColor` square with no radius or padding). Drawn
            // here in the glyph pass (behind the glyphs, like the #tag chips) so it
            // tracks the run exactly, including across line wraps.
            //
            // The pill is sized to the run's font ascent/descent and placed off the real
            // text baseline — NOT the line-fragment rect. The fragment is taller than the
            // glyph (and its top sits above the cap height), so filling it made the pill
            // too tall and raised above the surrounding text. Same technique as the card's
            // `HuggingLayoutManager`.
            ts.enumerateAttribute(.oakInlineCode, in: charRange, options: []) { value, range, _ in
                guard value != nil else { return }
                let font = (ts.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? NoteEditorStyle.monoFont
                let pad: CGFloat = 1.5, expand: CGFloat = 2
                let height = ceil(font.ascender - font.descender) + pad * 2
                let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                enumerateEnclosingRects(
                    forGlyphRange: gr,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    let glyph = self.glyphIndex(for: CGPoint(x: rect.minX + 1, y: rect.midY), in: container)
                    let baselineY = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                        + self.location(forGlyphAt: glyph).y
                    let left = max(rect.minX + origin.x - expand, 0)
                    let pill = NSRect(x: left,
                                      y: (baselineY + origin.y - font.ascender - pad).rounded(),
                                      width: rect.maxX + origin.x + expand - left,
                                      height: height)
                    NoteEditorStyle.codeBackground.setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                }
            }

            // Rounded #tag chips. Sized to the run's font ascent/descent off the real
            // baseline (same as the inline-code pill above) — NOT the line-fragment rect,
            // whose top sits above the cap height and rode the chip high above the text.
            ts.enumerateAttribute(.oakTag, in: charRange, options: []) { value, range, _ in
                guard value != nil else { return }
                let font = (ts.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? NoteEditorStyle.baseFont
                let pad: CGFloat = 1.5, expand: CGFloat = 3
                let height = ceil(font.ascender - font.descender) + pad * 2
                let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                enumerateEnclosingRects(
                    forGlyphRange: gr,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    let glyph = self.glyphIndex(for: CGPoint(x: rect.minX + 1, y: rect.midY), in: container)
                    let baselineY = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                        + self.location(forGlyphAt: glyph).y
                    let left = max(rect.minX + origin.x - expand, 0)
                    let chip = NSRect(x: left,
                                      y: (baselineY + origin.y - font.ascender - pad).rounded(),
                                      width: rect.maxX + origin.x + expand - left,
                                      height: height)
                    NoteEditorStyle.tagBackground.setFill()
                    NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
                }
            }

            // Inline math: draw each collapsed run's rendered image in the width its
            // first (hidden) character reserved via kern, vertically centred on the line.
            ts.enumerateAttribute(.oakMathImage, in: charRange, options: []) { value, range, _ in
                guard let image = value as? NSImage else { return }
                let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let lineRect = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
                let glyphLoc = location(forGlyphAt: gr.location)
                let x = lineRect.minX + glyphLoc.x + origin.x
                let y = lineRect.minY + origin.y + (lineRect.height - image.size.height) / 2
                image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1.0,
                           respectFlipped: true, hints: nil)
            }
        }
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    }
}
