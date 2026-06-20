import SwiftUI
import AppKit
import MarkdownEngine
import MarkdownEngineLatex
import MarkdownEngineCodeBlocks

// MARK: - Controller

/// Imperative handle the composer's toolbar drives. The editor edits a Markdown
/// *string* (the engine styles it live), so content lives in a `String` binding;
/// this controller reaches the engine's underlying `NSTextView` — captured via a
/// background introspection probe — only for caret-relative actions the binding
/// can't express (wrap selection, insert at caret, focus).
@MainActor
final class MarkdownNoteController {
    weak var textView: NSTextView?

    func focus() { if let tv = textView { tv.window?.makeFirstResponder(tv) } }

    /// Wrap the current selection in `marker` on both sides (e.g. `**bold**`); with
    /// no selection, insert the markers and place the caret between them.
    func wrapSelection(_ marker: String) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        if sel.length > 0 {
            let inner = ns.substring(with: sel)
            replace(sel, with: "\(marker)\(inner)\(marker)", caret: sel.location + marker.count + (inner as NSString).length)
        } else {
            replace(sel, with: "\(marker)\(marker)", caret: sel.location + marker.count)
        }
    }

    /// Prefix the caret's line with `prefix` (e.g. `> `, `- `, `1. `, `# `). Toggles
    /// off when the line already starts with it.
    func toggleLinePrefix(_ prefix: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: tv.selectedRange())
        let line = ns.substring(with: lineRange)
        if line.hasPrefix(prefix) {
            let stripped = String(line.dropFirst(prefix.count))
            replace(lineRange, with: stripped, caret: lineRange.location + (stripped as NSString).length)
        } else {
            replace(lineRange, with: prefix + line, caret: lineRange.location + (prefix as NSString).length)
        }
    }

    /// Insert literal text at the caret (e.g. a `#`/`@` trigger, a captured image).
    func insert(_ text: String) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        replace(sel, with: text, caret: sel.location + (text as NSString).length)
    }

    private func replace(_ range: NSRange, with text: String, caret: Int) {
        guard let tv = textView else { return }
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: caret, length: 0))
        }
        tv.window?.makeFirstResponder(tv)
    }
}

// MARK: - Editor view

/// The note composer's editing surface, backed by `swift-markdown-engine`
/// (`NativeTextViewWrapper`). The engine renders Markdown live (lists, quotes,
/// code, tables, links, task boxes) and round-trips through the `markdown`
/// binding, so there is no rich-attribute ⇄ Markdown codec to drift. Math and
/// code highlighting are plugged in via the ready-made `SwiftMathBridge` /
/// `HighlighterSwiftBridge`.
struct MarkdownEngineNoteEditor: View {
    @Binding var markdown: String
    let controller: MarkdownNoteController
    var fontSize: CGFloat = 14
    var placeholder: String = ""
    /// A finished region capture's `file://` URL, inserted as a Markdown image.
    var onPasteImage: ((NSPasteboard) -> String?)? = nil

    /// Math + syntax-highlighting services come from the package's drop-in bridges.
    private static let services = MarkdownEditorServices(
        syntaxHighlighter: HighlighterSwiftBridge(),
        latex: SwiftMathBridge()
    )

    var body: some View {
        NativeTextViewWrapper(
            text: $markdown,
            configuration: MarkdownEditorConfiguration(services: Self.services),
            fontName: "SF Pro",
            fontSize: fontSize,
            documentId: "note-composer",
            onPasteImage: onPasteImage,
            placeholder: placeholder.isEmpty ? nil : NSAttributedString(
                string: placeholder,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.placeholderTextColor,
                ]
            )
        )
        .background(TextViewProbe { controller.textView = $0 })
    }
}

// MARK: - NSTextView introspection

/// Captures the engine's underlying editable `NSTextView` so the toolbar can act
/// on the caret/selection. Placed as a `.background` of the editor, it walks up to
/// the shared SwiftUI container and finds the first scroll-view-hosted, editable
/// text view in that subtree (the composer hosts exactly one).
private struct TextViewProbe: NSViewRepresentable {
    let onFound: (NSTextView) -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let root = nsView.superview?.superview ?? nsView.superview else { return }
            if let tv = Self.firstEditableTextView(in: root) { onFound(tv) }
        }
    }

    private static func firstEditableTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable, tv.enclosingScrollView != nil { return tv }
        for sub in view.subviews {
            if let found = firstEditableTextView(in: sub) { return found }
        }
        return nil
    }
}
