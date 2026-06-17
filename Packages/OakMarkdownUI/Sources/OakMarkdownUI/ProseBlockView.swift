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
    /// Optional rich hover-preview for a link (e.g. a citation card). See
    /// `StreamingMarkdownView.linkPreview`.
    var linkPreview: ((URL, String) -> AnyView?)?

    func makeCoordinator() -> Coordinator { Coordinator(onOpenURL: onOpenURL, linkPreview: linkPreview) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenURL: ((URL) -> Bool)?
        var linkPreview: ((URL, String) -> AnyView?)?
        init(onOpenURL: ((URL) -> Bool)?, linkPreview: ((URL, String) -> AnyView?)?) {
            self.onOpenURL = onOpenURL
            self.linkPreview = linkPreview
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            // true → we handled it; false → NSTextView opens it via the default action.
            return onOpenURL?(url) ?? false
        }

        /// Suppress the default raw-URL tooltip for custom-scheme links (e.g.
        /// `oak://cite/…`) — their hover affordance is the preview card, not the raw URI,
        /// and that's true even when the card itself is suppressed as redundant. Plain
        /// web links (http/https) keep their normal tooltip.
        func textView(_ textView: NSTextView, willDisplayToolTip tooltip: String,
                      forCharacterAt characterIndex: Int) -> String? {
            guard let storage = textView.textStorage, characterIndex < storage.length,
                  let value = storage.attribute(.link, at: characterIndex, effectiveRange: nil),
                  let url = (value as? URL) ?? (value as? String).flatMap({ URL(string: $0) })
            else { return tooltip }
            let scheme = url.scheme?.lowercased()
            return (scheme == "http" || scheme == "https") ? tooltip : nil
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
        layoutManager.addTextContainer(container)

        let tv = MarkdownTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        // The container's wrap width is the SwiftUI-proposed width set in
        // `sizeThatFits`, NOT the text view's frame. `widthTracksTextView` must
        // stay false or AppKit re-derives the container width from the (often
        // stale/too-wide) frame, so long CJK lines stop wrapping and the whole
        // bubble balloons past a narrow chat panel. Set AFTER
        // `isHorizontallyResizable`, whose setter can flip tracking back on.
        container.widthTracksTextView = false
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: MarkdownTextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.linkPreview = linkPreview
        tv.linkPreview = linkPreview
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
        // Guard BOTH nil and non-finite proposals. SwiftUI probes a view's maximum
        // width by proposing `.infinity`; if we laid the text out at infinity it would
        // collapse to a single unwrapped line, and that natural single-line width would
        // leak back as the view's intrinsic width — ballooning the bubble past a narrow
        // chat panel where it gets clipped instead of wrapping. Clamp to a bounded
        // default so the real (finite) layout proposal is what governs wrapping.
        let proposed = proposal.width ?? 320
        let width = proposed.isFinite ? proposed : 320
        // Defensive: keep tracking off so the width we set below actually governs
        // wrapping (see makeNSView).
        container.widthTracksTextView = false
        container.containerSize = CGSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }
}
