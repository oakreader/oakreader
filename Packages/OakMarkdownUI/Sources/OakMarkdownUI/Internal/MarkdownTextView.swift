import AppKit

extension NSAttributedString.Key {
    /// Marks an inline-code run so `HuggingLayoutManager` draws it as a padded
    /// rounded pill rather than a bare selection-style rect.
    static let inlineCodePill = NSAttributedString.Key("OakMarkdownInlineCodePill")
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
        let expand: CGFloat = 4.5
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
final class MarkdownTextView: NSTextView {
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        return resigned
    }
}
