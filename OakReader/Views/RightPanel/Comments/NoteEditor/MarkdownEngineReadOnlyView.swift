import SwiftUI
import AppKit
import MarkdownEngine
import MarkdownEngineLatex
import MarkdownEngineCodeBlocks

// MARK: - Shared engine config

/// The single `swift-markdown-engine` configuration shared by the note *composer*
/// (`MarkdownEngineNoteEditor`) and the note *card* (`MarkdownEngineReadOnlyView`),
/// so the live input and the rendered preview are pixel-identical — same list
/// gutter, quote, code surface, math, and spacing. (This is the whole reason the
/// card renders with the engine instead of OakMarkdownUI.)
enum NoteMarkdownEngine {
    /// Math + syntax-highlighting via the package's drop-in bridges.
    static let services = MarkdownEditorServices(
        syntaxHighlighter: HighlighterSwiftBridge(),
        latex: SwiftMathBridge()
    )

    /// Tighter than the engine defaults: list indent 27.5→12pt, list line-height
    /// +2→+1, calmer paragraph spacing (0.3→0.18 of the line height).
    static let configuration = MarkdownEditorConfiguration(
        services: services,
        lists: ListStyle(indentPerLevel: 12, extraLineHeight: 1),
        paragraph: ParagraphStyle(spacingFactor: 0.18)
    )

    /// Card variant: same styling, but the view must hug its content (it's sized to
    /// fit in the stream), so kill the scrollers and the 40pt minimum overscroll —
    /// otherwise every card shows a scrollbar and clips.
    static let readOnlyConfiguration = MarkdownEditorConfiguration(
        services: services,
        lists: ListStyle(indentPerLevel: 12, extraLineHeight: 1),
        paragraph: ParagraphStyle(spacingFactor: 0.18),
        overscroll: OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0),
        scrollers: .hidden
    )
}

// MARK: - Read-only card renderer

/// Renders a note's Markdown body for the card stream using the *same* engine as
/// the composer (read-only), so input and preview never drift. The engine view is
/// a scroll view that fills its frame, so we measure the laid-out content height
/// (TextKit-2 `usageBoundsForTextContainer`, which depends on width not height — no
/// feedback loop) and pin the SwiftUI frame to it, making each card hug its text.
struct MarkdownEngineReadOnlyView: View {
    let markdown: String
    /// Stable per-note id: the engine scopes undo/per-document state to this.
    let documentId: String
    var fontSize: CGFloat = 14
    /// Return `true` if the URL was handled (e.g. `oak://note/<id>`, http).
    var onOpenURL: ((URL) -> Bool)? = nil

    @State private var height: CGFloat = 1

    var body: some View {
        NativeTextViewWrapper(
            text: .constant(markdown),
            configuration: NoteMarkdownEngine.readOnlyConfiguration,
            fontName: "SF Pro",
            fontSize: fontSize,
            documentId: documentId,
            isEditable: false,
            onLinkClick: { target in
                if let url = URL(string: target) { _ = onOpenURL?(url) }
            }
        )
        .frame(height: max(height, 1))
        .background(ContentHeightProbe { h in
            if abs(h - height) > 0.5 { height = h }
        })
    }
}

// MARK: - Content-height measurement

/// Measures the engine text view's laid-out content height and reports it up so the
/// read-only card can size to fit. Climbs to the composer's text view (same probe
/// strategy as the editor), reads the TextKit-2 used height, and re-measures on
/// frame changes — covering async growth as math/code images finish rendering.
private struct ContentHeightProbe: NSViewRepresentable {
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.start(from: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onHeight: ((CGFloat) -> Void)?
        private weak var textView: NSTextView?
        private var observer: NSObjectProtocol?
        private var tries = 0

        func start(from probe: NSView) {
            guard textView == nil else { measure(); return }
            tries = 0
            locate(from: probe)
        }

        private func locate(from probe: NSView) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let tv = Self.climb(from: probe) {
                    self.textView = tv
                    // Observe the content container's frame: it tracks the real content
                    // height (overscroll is zeroed for read-only), incl. async growth as
                    // math/code images finish.
                    let target: NSView = tv.enclosingScrollView?.documentView ?? tv
                    target.postsFrameChangedNotifications = true
                    self.observer = NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification, object: target, queue: .main
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.measure() } }
                    self.measure()
                } else if self.tries < 8 {
                    self.tries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.locate(from: probe) }
                }
            }
        }

        private func measure() {
            guard let tv = textView else { return }
            // Measure the *content* height only — NOT the scroll view's documentView,
            // which inflates to the viewport (my own frame) and feeds back into an
            // ever-growing empty box. TextKit-2 `usageBoundsForTextContainer` is
            // width-driven (no height feedback) so the card hugs its text.
            let inset = tv.textContainerInset.height * 2
            var h: CGFloat = 0
            if let tlm = tv.textLayoutManager {
                tlm.ensureLayout(for: tlm.documentRange)
                h = tlm.usageBoundsForTextContainer.height + inset
            } else if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                h = lm.usedRect(for: tc).height + inset
            }
            if h > 1 { onHeight?(ceil(h)) }
        }

        deinit {
            if let o = observer { NotificationCenter.default.removeObserver(o) }
        }

        static func climb(from probe: NSView) -> NSTextView? {
            var ancestor: NSView? = probe
            while let a = ancestor {
                if let tv = firstTextView(in: a) { return tv }
                ancestor = a.superview
            }
            return nil
        }

        private static func firstTextView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews {
                if let found = firstTextView(in: sub) { return found }
            }
            return nil
        }
    }
}
