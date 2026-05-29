import SwiftUI
import AppKit

/// Renders one prose block's attributed string in a self-sizing, non-editable NSTextView.
/// (Incremental tail editing via `replaceCharacters` is a later refinement; the block-stack
/// memoizes settled blocks so only the trailing block ever re-renders.)
struct ProseBlockView: NSViewRepresentable {
    let attributed: NSAttributedString
    let selectable: Bool
    /// Called when a link is clicked. Return `true` if handled (the click is
    /// consumed); return `false` to let the text view open it normally (system
    /// browser). Lets the host intercept custom schemes (e.g. `oak://`) that the
    /// OS has no handler for, instead of letting AppKit fail to open them.
    var onOpenURL: ((URL) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(onOpenURL: onOpenURL) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenURL: ((URL) -> Bool)?
        init(onOpenURL: ((URL) -> Bool)?) { self.onOpenURL = onOpenURL }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            // true → we handled it; false → NSTextView opens it via the default action.
            return onOpenURL?(url) ?? false
        }
    }

    func makeNSView(context: Context) -> MarkdownTextView {
        // Build a TextKit 1 stack explicitly so our custom layout manager (rounded,
        // glyph-hugging backgrounds) is actually used — a default NSTextView would
        // create its own layout manager.
        let storage = NSTextStorage()
        let layoutManager = HuggingLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: CGFloat(0), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = MarkdownTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: MarkdownTextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: MarkdownTextView, context: Context) -> CGSize? {
        guard let container = tv.textContainer, let lm = tv.layoutManager else { return nil }
        let width = proposal.width ?? 320
        container.containerSize = CGSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }
}
