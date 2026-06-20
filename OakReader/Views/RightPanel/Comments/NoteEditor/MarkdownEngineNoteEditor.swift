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
    func wrapSelection(_ marker: String) { wrapSelection(open: marker, close: marker) }

    /// Wrap the selection in distinct opening/closing markers (e.g. `<u>…</u>`).
    func wrapSelection(open: String, close: String) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        let inner = sel.length > 0 ? ns.substring(with: sel) : ""
        let caret = sel.location + (open as NSString).length + (inner as NSString).length
        replace(sel, with: open + inner + close, caret: caret)
    }

    /// Insert a fenced code block, caret placed on the empty middle line.
    func insertCodeBlock() {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        let fence = "```\n\n```"
        replace(sel, with: fence, caret: sel.location + 4)  // after "```\n"
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

    /// Tighter than the engine defaults, which read as over-indented/loose in a
    /// compact composer: list indent 27.5→18pt (matches the engine's fixed 18pt
    /// blockquote indent and the rendered note card), list line-height +2→+1, and
    /// calmer paragraph spacing (0.3→0.18 of the line height).
    private static let configuration = MarkdownEditorConfiguration(
        services: services,
        lists: ListStyle(indentPerLevel: 18, extraLineHeight: 1),
        paragraph: ParagraphStyle(spacingFactor: 0.18)
    )

    var body: some View {
        NativeTextViewWrapper(
            text: $markdown,
            configuration: Self.configuration,
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
/// on the caret/selection. Placed as a `.background` of the editor, it climbs its
/// ancestors one level at a time and, at each level, searches that subtree for the
/// composer's editable text view. Climbing from the probe (which sits right next to
/// the editor) finds the composer's own text view well before reaching the window
/// root — so it never grabs the PDF/chat/search text views elsewhere in the window.
private struct TextViewProbe: NSViewRepresentable {
    let onFound: (NSTextView) -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        attempt(from: nsView, tries: 8)
    }

    /// Retry a few times: on the first SwiftUI update the engine's text view may not
    /// be in the hierarchy yet.
    private func attempt(from probe: NSView, tries: Int) {
        DispatchQueue.main.async {
            if let tv = Self.climbForTextView(from: probe) {
                onFound(tv)
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    attempt(from: probe, tries: tries - 1)
                }
            }
        }
    }

    private static func climbForTextView(from probe: NSView) -> NSTextView? {
        var ancestor: NSView? = probe
        while let a = ancestor {
            if let tv = firstEditableTextView(in: a) { return tv }
            ancestor = a.superview
        }
        return nil
    }

    private static func firstEditableTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for sub in view.subviews {
            if let found = firstEditableTextView(in: sub) { return found }
        }
        return nil
    }
}
