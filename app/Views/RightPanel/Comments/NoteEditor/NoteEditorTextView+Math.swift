import AppKit
import OakMarkdownUI

// MARK: - Inline math ($…$) live rendering

extension NoteEditorTextView {

    /// Matches block `$$…$$` (group 1) or inline `$…$` (group 2). Inline content
    /// must start and end with a non-space so prose like "$5 and $10" (currency)
    /// is NOT mistaken for math.
    // swiftlint:disable:next force_try
    private static let mathRegex = try! NSRegularExpression(
        pattern: #"\$\$([^$]+?)\$\$|\$(\S(?:[^$\n]*\S)?)\$"#)

    /// A ~zero-width clear font that hides the raw `$…$` source while the rendered
    /// image is shown — the source characters stay in the buffer (so Markdown
    /// round-trips and editing is natural), they're just not drawn.
    private static let mathMarkerFont = NSFont.systemFont(ofSize: 0.01)

    /// Collapse every `$…$` / `$$…$$` run the caret is NOT inside into its rendered
    /// formula image; reveal the raw source of the run the caret IS inside. Adapted
    /// from swift-markdown-engine's approach: keep the source text, hide it with a
    /// clear font, reserve the image's width via `kern`, and draw the image in the
    /// layout manager — so typing, selection, and undo all act on real characters.
    func restyleMath() {
        guard let ts = textStorage, !isRestylingMath else { return }
        let str = ts.string
        let sel = selectedRange()

        // Skip when nothing math-relevant changed: a single command fires this 2–3×
        // and every caret move calls it, but only a text edit or a selection move
        // that crosses a formula needs work. The (length + content-hash + selection)
        // fingerprint makes those redundant calls — the source of the toolbar lag —
        // near-free, and never touches `beginEditing` (which invalidates layout).
        let signature = "\(str.utf16.count)|\(str.hashValue)|\(sel.location)|\(sel.length)"
        if signature == lastMathSignature { return }
        lastMathSignature = signature

        // Fast path: no `$` and no live math runs ⇒ nothing to render or clean up.
        if !str.contains("$"), !hasMathRuns(ts) { return }

        isRestylingMath = true
        defer { isRestylingMath = false }

        let full = NSRange(location: 0, length: ts.length)
        let nsString = str as NSString

        ts.beginEditing()
        // 1. Reset every previously-collapsed run to editable plain text (covers
        //    edits, deletions, and caret-enter).
        ts.enumerateAttribute(.oakMath, in: full, options: []) { value, range, _ in
            guard value != nil, NSMaxRange(range) <= ts.length else { return }
            ts.removeAttribute(.oakMath, range: range)
            ts.removeAttribute(.oakMathImage, range: range)
            ts.removeAttribute(.kern, range: range)
            ts.addAttribute(.font, value: NoteEditorStyle.baseFont, range: range)
            ts.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }

        // 2. Collapse every inactive run into its image.
        let fontSize = NoteEditorStyle.baseFont.pointSize
        for m in Self.mathRegex.matches(in: ts.string, range: full) {
            let runRange = m.range
            let isBlock = m.range(at: 1).location != NSNotFound
            let contentRange = isBlock ? m.range(at: 1) : m.range(at: 2)
            guard contentRange.location != NSNotFound else { continue }

            // Active when the caret/selection touches the run (incl. trailing edge).
            let touch = NSRange(location: runRange.location, length: runRange.length + 1)
            let active = sel.length == 0
                ? (sel.location >= runRange.location && sel.location <= NSMaxRange(runRange))
                : NSIntersectionRange(touch, sel).length > 0
            if active { continue }

            let latex = nsString.substring(with: contentRange)
            guard let image = MathImageRenderer.image(
                latex: latex, fontSize: fontSize + 1, color: .labelColor, display: isBlock
            ) else { continue }

            ts.addAttribute(.oakMath, value: latex, range: runRange)
            ts.addAttribute(.font, value: Self.mathMarkerFont, range: runRange)
            ts.addAttribute(.foregroundColor, value: NSColor.clear, range: runRange)
            let firstChar = NSRange(location: runRange.location, length: 1)
            ts.addAttribute(.oakMathImage, value: image, range: firstChar)
            ts.addAttribute(.kern, value: image.size.width, range: firstChar)   // reserve the image width
        }
        ts.endEditing()
    }

    /// Whether any collapsed-math run is still present — so the no-`$` fast path
    /// still cleans up a stale hidden run left behind when a delimiter was deleted.
    private func hasMathRuns(_ ts: NSTextStorage) -> Bool {
        var found = false
        ts.enumerateAttribute(.oakMath, in: NSRange(location: 0, length: ts.length), options: []) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
}
