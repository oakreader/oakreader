import AppKit

// MARK: - Layout manager (#tag chips, block decorations, inline math)

/// Custom `NSLayoutManager` that paints what plain attributes can't: rounded
/// `#tag` chips, continuous block backgrounds (quote fill + rule, code fill), and
/// inline math images. All decoration reads already-laid-out geometry so it never
/// forces a re-layout during drawing.
final class NoteTagLayoutManager: NSLayoutManager {
    /// Paragraph-level decoration (quote fill + rule, code-block fill) belongs in
    /// the *background* pass — it runs before glyphs, is the API designed for
    /// backgrounds, and reads completed layout so it never forces a re-layout.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
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
            // Union the *used* rects (tight glyph box), NOT the full line-fragment rects:
            // the fragment also covers the paragraph's spacing-before/after, which would
            // pull that spacing INSIDE the fill (fat inner padding, the bug). Building from
            // the used rect keeps the grey tight to the text, so `paragraphSpacing*` lands
            // OUTSIDE the fill as real outer margin between the block and nearby lines.
            enumerateLineFragments(forGlyphRange: gr) { _, usedRect, _, _, _ in
                box = box.union(usedRect)
            }
            // A block you're still typing into can end on an empty (glyph-less) line —
            // the extra line fragment — which `enumerateLineFragments` skips. Fold it in
            // when the run reaches the end of the text so the current line stays filled.
            if NSMaxRange(runRange) >= storageLen, !extraLineFragmentUsedRect.isEmpty {
                box = box.union(extraLineFragmentUsedRect)
            }
            guard !box.isNull, !box.isEmpty else { continue }
            let y = box.minY + origin.y

            switch block {
            case .quote:
                // Match the saved note card exactly (WYSIWYG): a soft rounded fill,
                // NO left bar. The card's `HuggingLayoutManager` deliberately draws
                // fill-only ("the bar on top of it was redundant chrome"), so the
                // editor preview mirrors its geometry — inset 2pt per side, padded
                // 4pt vertically, corner radius 5 — and its head-indent (12pt, set in
                // `NoteEditorStyle.paragraphStyle`).
                let sideInset: CGFloat = 2, vPad: CGFloat = 4
                let fill = NSRect(x: origin.x + sideInset, y: y - vPad,
                                  width: max(fullWidth - sideInset * 2, 0),
                                  height: box.height + vPad * 2)
                NoteEditorStyle.quoteBackground.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5).fill()
            case .code:
                // Mirror the saved card's `CodeBlockView` surface so the editor
                // preview isn't a cramped grey strip: a filled, hairline-bordered
                // rounded block with real vertical breathing room (the card pads its
                // code 8pt vertically). One continuous fill over all the block's lines
                // (replaces the old per-line `.backgroundColor`, which striped).
                // Tight inner padding now: the fill hugs the glyphs (used rect), so a small
                // vPad is enough; the block's outer breathing room comes from its
                // `paragraphSpacingBefore/After`, which sits outside this grey.
                let sideInset: CGFloat = 6, vPad: CGFloat = 3
                let fill = NSRect(x: origin.x + sideInset, y: y - vPad,
                                  width: max(fullWidth - sideInset * 2, 0),
                                  height: box.height + vPad * 2)
                NoteEditorStyle.codeBlockBackground.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 8, yRadius: 8).fill()
                let border = NSBezierPath(roundedRect: fill.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                border.lineWidth = 1
                NoteEditorStyle.codeBlockBorder.setStroke()
                border.stroke()
            default:
                break
            }
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

            // Rounded #tag chips.
            ts.enumerateAttribute(.oakTag, in: charRange, options: []) { value, range, _ in
                guard value != nil else { return }
                let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                enumerateEnclosingRects(
                    forGlyphRange: gr,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    // Pad horizontally into the surrounding spaces + a hair vertically,
                    // so the fill reads as a chip without changing text layout.
                    let chip = NSRect(x: rect.minX + origin.x - 3, y: rect.minY + origin.y,
                                      width: rect.width + 6, height: rect.height - 1)
                    let path = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)
                    NoteEditorStyle.tagBackground.setFill()
                    path.fill()
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
