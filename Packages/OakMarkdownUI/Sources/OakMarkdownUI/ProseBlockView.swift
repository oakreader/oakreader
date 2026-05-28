import SwiftUI
import AppKit

/// Renders one prose block's attributed string in a self-sizing, non-editable NSTextView.
/// (Incremental tail editing via `replaceCharacters` is a later refinement; the block-stack
/// memoizes settled blocks so only the trailing block ever re-renders.)
struct ProseBlockView: NSViewRepresentable {
    let attributed: NSAttributedString
    let selectable: Bool

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        tv.isSelectable = selectable
        guard let ts = tv.textStorage else { return }
        if ts.length == 0 {
            ts.setAttributedString(attributed)
            return
        }
        // Incremental: keep the common prefix (chars + attributes), replace only the
        // diverging suffix → TextKit re-lays-out just that glyph range (Dia's append-in-place).
        let divergence = Self.firstDivergence(ts, attributed)
        if divergence == ts.length, divergence == attributed.length { return }
        let oldTail = NSRange(location: divergence, length: ts.length - divergence)
        let newTail = attributed.attributedSubstring(
            from: NSRange(location: divergence, length: attributed.length - divergence))
        ts.beginEditing()
        ts.replaceCharacters(in: oldTail, with: newTail)
        ts.endEditing()
    }

    /// First index where the two attributed strings differ in character or attributes.
    private static func firstDivergence(_ a: NSAttributedString, _ b: NSAttributedString) -> Int {
        let sa = a.string as NSString
        let sb = b.string as NSString
        let n = min(sa.length, sb.length)
        var i = 0
        while i < n {
            if sa.character(at: i) != sb.character(at: i) { break }
            let aAttrs = a.attributes(at: i, effectiveRange: nil) as NSDictionary
            let bAttrs = b.attributes(at: i, effectiveRange: nil) as NSDictionary
            if !aAttrs.isEqual(bAttrs) { break }
            i += 1
        }
        return i
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let container = tv.textContainer, let lm = tv.layoutManager else { return nil }
        let width = proposal.width ?? 320
        container.containerSize = CGSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }
}
