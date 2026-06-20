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
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
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
        layout.addTextContainer(container)

        let tv = NoteEditorTextView(frame: .zero, textContainer: container)
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.font = NoteEditorStyle.baseFont
        tv.typingAttributes = [.font: NoteEditorStyle.baseFont, .foregroundColor: NSColor.labelColor]

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
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NoteEditorTextView else { return }
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
