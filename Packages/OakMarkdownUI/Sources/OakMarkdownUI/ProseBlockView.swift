import SwiftUI
import AppKit

/// Renders one prose block's attributed string in a self-sizing, non-editable NSTextView.
/// (Incremental tail editing via `replaceCharacters` is a later refinement; the block-stack
/// memoizes settled blocks so only the trailing block ever re-renders.)
struct ProseBlockView: NSViewRepresentable {
    let attributed: NSAttributedString
    let selectable: Bool
    /// When true, text appended since the last render fades in (Dia's glyph reveal)
    /// instead of appearing instantly. Only the streaming trailing block sets this.
    var animatesAppendedText: Bool = false
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
        // Let AppKit keep the display container's wrap width synced to the text view's
        // committed frame on every layout pass — including the moment a streamed answer
        // settles, when nothing else re-pins it. This is the *only* thing that sets the
        // display wrap width: `sizeThatFits` measures height through a separate, never-drawn
        // container (see `MarkdownTextView.measuredHeight`), so a wide measurement probe can
        // no longer leak into the rendered view and clip the settled bubble. Set AFTER
        // `isHorizontallyResizable`, whose setter can flip tracking off.
        container.widthTracksTextView = true
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: MarkdownTextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.linkPreview = linkPreview
        tv.linkPreview = linkPreview
        tv.isSelectable = selectable
        // Set before mutating storage so the first fade applies alpha 0 synchronously
        // (no full-opacity flash before the first animation frame).
        tv.fadesAppendedText = animatesAppendedText
        guard let ts = tv.textStorage else { return }
        if ts.length == 0 {
            ts.setAttributedString(attributed)
            tv.fadeInAppendedText(NSRange(location: 0, length: attributed.length))
            return
        }
        // Incremental: keep the common prefix (chars + attributes), replace only the
        // diverging suffix → TextKit re-lays-out just that glyph range (Dia's append-in-place).
        let oldLength = ts.length
        let divergence = Self.firstDivergence(ts, attributed)
        if divergence == ts.length, divergence == attributed.length { return }
        let oldTail = NSRange(location: divergence, length: ts.length - divergence)
        let newTail = attributed.attributedSubstring(
            from: NSRange(location: divergence, length: attributed.length - divergence))
        ts.beginEditing()
        ts.replaceCharacters(in: oldTail, with: newTail)
        ts.endEditing()
        // Fade in ONLY the genuinely-new trailing glyphs — [oldLength, end). The text is
        // append-only, so anything before `oldLength` was already on screen; `divergence`
        // can sit far earlier than that when late inline markdown finishes parsing (a
        // link/citation, bold, or a list marker restyles text that was already visible).
        // Re-fading that restyled-but-seen run from transparent on every delta is what made
        // the streamed answer flicker and pop paragraph-by-paragraph. Snap any in-flight
        // fade over the rewritten region to full opacity (so it isn't left stuck dim), then
        // fade just the appended tail.
        tv.finalizeFades(before: oldLength)
        if attributed.length > oldLength {
            tv.fadeInAppendedText(NSRange(location: oldLength, length: attributed.length - oldLength))
        }
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
        // When SwiftUI offers a concrete finite width (the real layout), FILL it: that width
        // came from the container, so the view can never be wider than its panel. Height is
        // measured through the text view's *separate* measuring container — never the display
        // container — so the measurement can't leak a wrap width into what's rendered (the
        // display container's width is pinned to the frame by `widthTracksTextView`). That is
        // what keeps a settled answer from clipping.
        if let proposed = proposal.width, proposed.isFinite {
            return CGSize(width: proposed, height: tv.measuredHeight(forWidth: proposed))
        }
        // Ambiguous proposal (`nil` ideal / `.infinity` max): report the MINIMUM width the
        // text needs, not a fixed default. A fixed default (e.g. 320) larger than the panel's
        // content area is exactly what pushed the bubble outside the panel. Reporting the
        // minimum lets the enclosing `.frame(maxWidth: .infinity)` size the column to the
        // panel; the concrete-width branch above then fills it.
        let minWidth = tv.minimumContentWidth()
        return CGSize(width: minWidth, height: tv.measuredHeight(forWidth: minWidth))
    }
}
