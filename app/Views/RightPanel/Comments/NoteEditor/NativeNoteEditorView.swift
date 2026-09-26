import SwiftUI
import AppKit

// MARK: - Controller

/// Imperative handle the composer's toolbar drives — every formatting button and
/// the `@`/`#` pickers route through here to the live `NoteEditorTextView`.
@MainActor
final class NoteEditorController {
    weak var textView: NoteEditorTextView?

    func cmd(_ name: String) {
        if name == "tag" { textView?.requestPicker(.tag); return }
        textView?.runCommand(name)
        // Pull focus straight back into the editor. A block toggle (quote/code) on an
        // empty line lives only in `typingAttributes`; if the user then *clicks* into
        // an unfocused editor to start typing, AppKit resets those attributes and the
        // block silently never applies — so it neither shows while typing nor
        // serializes to `>`/```` ``` ```` for the saved card. Focusing here means they
        // can type immediately and the block sticks. Lists already survive via their
        // inserted marker run; this makes quote/code as robust.
        if let tv = textView { tv.window?.makeFirstResponder(tv) }
    }
    func focus() { if let tv = textView { tv.window?.makeFirstResponder(tv) } }
    func clear() { textView?.setMarkdown("") }
    func insertLink(url: String) { textView?.applyLink(url: url) }
    func requestMention() { textView?.requestPicker(.mention) }
    func requestTag() { textView?.requestPicker(.tag) }
    /// The buffer is rich text; serialize to Markdown on demand.
    func getMarkdown(_ completion: @escaping (String) -> Void) {
        completion(textView.map { NoteMarkdownCodec.markdown(from: $0.currentAttributedString()) } ?? "")
    }
}

// MARK: - Representable

/// Bridges the AppKit `NoteEditorTextView` into SwiftUI. The editor is a true
/// WYSIWYG surface; see the sibling files for the pieces:
/// `NoteEditorModel` (attribute keys + block enum), `NoteEditorStyle` (tokens),
/// `NoteMarkdownCodec` (Markdown ⇄ attributed), `NoteTagLayoutManager` (chip /
/// block / math drawing), `NoteEditorTextView` (+`+Math`) (the live text view).
struct NativeNoteEditorView: NSViewRepresentable {
    let initialMarkdown: String
    let controller: NoteEditorController
    @Binding var isEmpty: Bool
    @Binding var charCount: Int
    @Binding var height: CGFloat
    @Binding var activeFormats: Set<String>
    var minHeight: CGFloat = 44
    var maxHeight: CGFloat = 220
    var onSubmit: () -> Void = {}
    /// Other notes the `@` panel can reference, and existing `#tags` it offers.
    var references: [NoteRef] = []
    var tags: [String] = []
    /// A `#` tag typed/created that isn't in `tags` yet (so the host can persist it).
    var onCreateTag: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = NoteEditorClipView()
        scroll.drawsBackground = false
        // The editor auto-grows up to `maxHeight` (the SwiftUI frame tracks the
        // reported content height); past that it's a fixed box whose content must
        // scroll. Show the overlay scroller so the user can reach the overflow — and
        // so a long note isn't silently clipped under the fold.
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        // Manual TextKit-1 stack so we can install a custom layout manager that
        // draws rounded `#tag` chips, block backgrounds, and inline math.
        let storage = NSTextStorage()
        let layout = NoteTagLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Match the card body (OakMarkdownUI uses lineFragmentPadding 0 + zero inset):
        // the container's default 5pt fragment padding plus the 4pt textContainerInset
        // below would push the composer text ~9pt further right than the rendered note,
        // so the caret didn't line up with the card text. Zero it to align them.
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = NoteEditorTextView(frame: .zero, textContainer: container)
        tv.maxAutoGrowHeight = maxHeight
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true
        // Width 0 aligns text with the rendered note body. The 5pt vertical inset keeps
        // the first-line block surface compact; the clip view below handles scroll pinning.
        tv.textContainerInset = NSSize(width: 0, height: 5)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        // Standard "text view in a scroll view" recipe: without a tall maxSize the
        // document view can't extend below the clip bounds, so once the box caps at
        // `maxHeight` the overflow is unreachable. Let it grow unbounded vertically;
        // the visible box stays clamped by the SwiftUI frame, the rest scrolls.
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.font = NoteEditorStyle.baseFont
        tv.typingAttributes = NoteEditorStyle.defaultTypingAttributes
        // Match the AI chat input's caret: a neutral `.labelColor` (black in light mode,
        // white in dark) rather than the system-accent blue the editor defaulted to.
        tv.insertionPointColor = .labelColor

        tv.onSubmit = { onSubmit() }
        tv.onChange = { empty, count in
            if isEmpty != empty { isEmpty = empty }
            if charCount != count { charCount = count }
        }
        tv.onActiveFormats = { set in if activeFormats != set { activeFormats = set } }
        tv.onHeight = { used in
            let clamped = min(max(used, minHeight), maxHeight)
            if abs(clamped - height) > 0.5 { height = clamped }
        }
        tv.onCreateTag = { onCreateTag?($0) }
        tv.references = references
        tv.tags = tags

        scroll.documentView = tv
        controller.textView = tv
        tv.setMarkdown(initialMarkdown)
        // Seed the auto-grow height AFTER construction: the height report from
        // `setMarkdown` above runs during `makeNSView`, where a SwiftUI binding
        // mutation is dropped — so an existing multi-line note (edit mode) would open
        // at the floor height with a scrollbar. Deferring one runloop tick (the text
        // view now has its real width) makes it open grown-to-fit, Slack-style.
        // Mirrors `ChatInputTextView`'s deferred `updateHeight()`.
        DispatchQueue.main.async { [weak tv] in tv?.reportHeightNow() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NoteEditorTextView else { return }
        tv.maxAutoGrowHeight = maxHeight
        tv.references = references
        tv.tags = tags
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textDidChange(_ notification: Notification) {
            (notification.object as? NoteEditorTextView)?.handleTextChange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NoteEditorTextView)?.reportActiveFormats()
        }
    }
}

/// Enforces the editor's two modes at the scroll boundary: grow-mode is pinned to the
/// top; overflow mode scrolls normally.
private final class NoteEditorClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        if let tv = documentView as? NoteEditorTextView, tv.shouldPinClipViewToTop {
            bounds.origin.y = 0
        }
        return bounds
    }
}
