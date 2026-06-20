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
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fullWidth = container.size.width

        // Paragraph decorations (quote fill + left rule; code-block fill) are drawn
        // here — the background pass — reading already-laid-out line fragments via
        // `enumerateLineFragments` (the idiomatic, layout-safe API; `boundingRect`
        // would force layout *during* drawing). A per-character `.backgroundColor`
        // attribute can't do these: it fills ragged, tight per-line rects with gaps
        // (a striped, broken look). One unioned rect reads as a single clean block.
        ts.enumerateAttribute(.oakBlock, in: charRange, options: []) { value, range, _ in
            guard let raw = value as? Int, let block = NoteBlock(rawValue: raw),
                  block == .quote || block == .code else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = NSRect.null
            enumerateLineFragments(forGlyphRange: gr) { rect, _, _, _, _ in
                box = box.union(rect)
            }
            guard !box.isNull, !box.isEmpty else { return }
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
                let sideInset: CGFloat = 2, vPad: CGFloat = 6
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
