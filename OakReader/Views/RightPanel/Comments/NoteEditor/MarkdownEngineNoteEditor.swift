import SwiftUI
import AppKit
import MarkdownEngine
import MarkdownEngineLatex
import MarkdownEngineCodeBlocks

// MARK: - Shared engine config

/// The `swift-markdown-engine` configuration used by the note *composer*. (Note
/// *cards* render with OakMarkdownUI `StreamingMarkdownView(.oak())`, which sizes
/// to its content intrinsically — the engine is a scroll view and only earns its
/// keep for live editing.)
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
}

// MARK: - Controller

/// Imperative handle the composer's toolbar drives. The editor edits a Markdown
/// *string* (the engine styles it live), so content lives in a `String` binding;
/// this controller reaches the engine's underlying `NSTextView` — captured via a
/// background introspection probe — for caret-relative actions the binding can't
/// express (wrap selection, insert at caret, focus) and for the inline `#`/`@`
/// completion popup.
///
/// `swift-markdown-engine` owns its text view and we can't subclass it, so the
/// `#`/`@` popup is driven from the *outside*: we observe the text view's change
/// and selection notifications to detect triggers and filter, and install a local
/// key monitor to steer the panel (↑/↓/⏎/esc) while it's open — mirroring the AI
/// chat composer's `ChatNSTextView`, but without owning `keyDown`.
@MainActor
final class MarkdownNoteController {
    weak var textView: NSTextView?

    /// Other notes the `@` panel can reference, and existing `#tags` it offers.
    var references: [NoteRef] = []
    var tags: [String] = []
    /// A `#` tag typed/created that isn't in `tags` yet (so the host can persist it).
    var onCreateTag: ((String) -> Void)?
    /// Reports the editor's *pure text* content height (excludes the engine's
    /// scroll overscroll) so the host can size the composer to hug its content
    /// instead of stretching to the engine `NSScrollView`'s flexible frame.
    var onHeight: ((CGFloat) -> Void)?

    private var completionPanel: ChatCompletionPanel?
    private var triggerChar: String?
    private var triggerLocation: Int?
    private var keyMonitor: Any?
    private var textObserver: NSObjectProtocol?
    private var selObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    /// De-dupes height reports (TextKit echoes frame changes during typing).
    private var lastReportedHeight: CGFloat = -1
    /// Guards programmatic edits (token insertion) from re-triggering detection.
    private var isProgrammatic = false

    // MARK: Attach / teardown

    /// Bind to the engine's text view (idempotent). Installs the change/selection
    /// observers and the local key monitor that power the completion popup.
    func attach(_ tv: NSTextView) {
        guard textView !== tv else { return }
        teardown()
        textView = tv
        textObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: tv, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reportHeight(); self?.onTextChanged() } }
        selObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: tv, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onSelectionChanged() } }
        // The engine's text view is vertically resizable, so its frame changes
        // whenever content height changes (typing) or width changes (re-wrap) —
        // re-measure on either so the composer keeps hugging its content.
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: tv, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reportHeight() } }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        }
        reportHeight()
    }

    private func teardown() {
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        if let o = textObserver { NotificationCenter.default.removeObserver(o); textObserver = nil }
        if let o = selObserver { NotificationCenter.default.removeObserver(o); selObserver = nil }
        if let o = frameObserver { NotificationCenter.default.removeObserver(o); frameObserver = nil }
        dismissPanel()
    }

    deinit {
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        if let o = textObserver { NotificationCenter.default.removeObserver(o) }
        if let o = selObserver { NotificationCenter.default.removeObserver(o) }
        if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Content height

    /// Measure the laid-out text height (TextKit 2 usage bounds, *not* the text
    /// view frame — that includes the engine's scroll overscroll, min 40pt) and
    /// report it when it changes. The host clamps it to the composer's range.
    private func reportHeight() {
        guard let tv = textView, let tlm = tv.textLayoutManager else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        let h = tlm.usageBoundsForTextContainer.height + tv.textContainerInset.height * 2
        guard h > 0, abs(h - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = h
        onHeight?(h)
    }

    /// Imperatively empty the editor (used when the composer clears on save).
    ///
    /// Setting the `markdown` *binding* to `""` is a programmatic change that the
    /// engine doesn't echo as a height/frame notification (`NSText.didChange` is for
    /// user edits only, and it doesn't fire `frameDidChange` on a programmatic
    /// shrink), so the box would stay stuck at its tall size. Replacing the text
    /// directly fires `didChangeText` — which the engine observes to re-sync the
    /// `markdown` binding back to "" — and lets us re-measure against the now-empty
    /// content so the composer collapses back to its floor. Mirrors main's native
    /// editor `clear()`.
    func clear() {
        guard let tv = textView else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        guard full.length > 0 else { reportHeight(); return }
        isProgrammatic = true
        if tv.shouldChangeText(in: full, replacementString: "") {
            tv.textStorage?.replaceCharacters(in: full, with: "")
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        isProgrammatic = false
        // When the note overflowed 220pt the engine's scroll view was scrolled down;
        // after collapsing to the floor that leftover offset leaves a stranded
        // scroller. Snap the clip view back to the top and let it recompute scroller
        // visibility against the now-tiny content so the bar disappears.
        if let sv = tv.enclosingScrollView {
            sv.contentView.scroll(to: .zero)
            sv.reflectScrolledClipView(sv.contentView)
        }
        // Re-measure now that the view actually holds empty content.
        lastReportedHeight = -1
        reportHeight()
    }

    // MARK: Toolbar actions

    func focus() { if let tv = textView { tv.window?.makeFirstResponder(tv) } }

    /// Wrap the current selection in `marker` on both sides (e.g. `**bold**`); with
    /// no selection, insert the markers and place the caret between them.
    func wrapSelection(_ marker: String) { wrapSelection(open: marker, close: marker) }

    /// Wrap the selection in distinct opening/closing markers (e.g. `**…**`). With
    /// no selection, wrap the *word under the caret* so clicking Bold on a word just
    /// bolds it — instead of dropping bare `****` markers the user must type into.
    func wrapSelection(open: String, close: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var sel = tv.selectedRange()
        if sel.length == 0 {
            let word = tv.selectionRange(forProposedRange: sel, granularity: .selectByWord)
            if word.length > 0,
               !ns.substring(with: word).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sel = word
            }
        }
        let inner = sel.length > 0 ? ns.substring(with: sel) : ""
        let caret = sel.location + (open as NSString).length + (inner as NSString).length
        replace(sel, with: open + inner + close, caret: caret)
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

    /// Insert literal text at the caret (e.g. a `#`/`@` trigger from the toolbar —
    /// the change observer then opens the completion panel just as if typed).
    func insert(_ text: String) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        replace(sel, with: text, caret: sel.location + (text as NSString).length)
    }

    /// Insert a fenced code block, caret placed on the empty middle line.
    func insertCodeBlock() {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        replace(sel, with: "```\n\n```", caret: sel.location + 4)  // after "```\n"
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

    // MARK: Completion — detection

    private func onTextChanged() {
        guard !isProgrammatic, let tv = textView else { return }
        if completionPanel != nil { updateFilter(); return }
        let caret = tv.selectedRange().location
        let ns = tv.string as NSString
        guard caret > 0, caret <= ns.length else { return }
        let ch = ns.substring(with: NSRange(location: caret - 1, length: 1))
        guard ch == "#" || ch == "@", atWordBoundary(caret - 1, ns) else { return }
        showPanel(trigger: ch, at: caret - 1)
    }

    private func onSelectionChanged() {
        guard completionPanel != nil, let tv = textView, let start = triggerLocation else { return }
        // Caret jumped out of the trigger run → close.
        let caret = tv.selectedRange().location
        if caret <= start { dismissPanel() }
    }

    private func atWordBoundary(_ loc: Int, _ ns: NSString) -> Bool {
        guard loc > 0 else { return true }
        let prev = ns.substring(with: NSRange(location: loc - 1, length: 1))
        guard let scalar = prev.unicodeScalars.first else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: Completion — panel

    private func showPanel(trigger: String, at loc: Int) {
        let items = completionItems(for: trigger)
        guard !items.isEmpty, let tv = textView, let rect = composerScreenRect(tv) else { return }
        dismissPanel()
        triggerChar = trigger
        triggerLocation = loc
        let panel = ChatCompletionPanel(
            items: items,
            anchorRect: rect,
            screenVisibleFrame: composerVisibleFrame(tv)
        ) { [weak self] item in self?.performSelect(item) }
        completionPanel = panel
        tv.window?.addChildWindow(panel, ordered: .above)
    }

    private func dismissPanel() {
        completionPanel?.dismiss()
        completionPanel = nil
        triggerChar = nil
        triggerLocation = nil
    }

    /// Intercept navigation keys while the panel is open and the editor has focus;
    /// return `nil` to swallow, or the event to let the text view handle it (which
    /// then re-filters via the change observer).
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard completionPanel != nil, let tv = textView, tv.window?.firstResponder === tv else {
            return event
        }
        switch event.keyCode {
        case 53: dismissPanel(); return nil                                   // Esc
        case 36, 48:                                                          // Enter / Tab
            if let item = completionPanel?.selectedItem { performSelect(item) } else { dismissPanel() }
            return nil
        case 126: completionPanel?.moveSelection(by: -1); return nil          // Up
        case 125: completionPanel?.moveSelection(by: 1); return nil           // Down
        default: return event                                                // type → re-filter
        }
    }

    private func updateFilter() {
        guard let panel = completionPanel, let tv = textView, let start = triggerLocation else { return }
        let caret = tv.selectedRange().location
        let from = start + 1
        let ns = tv.string as NSString
        guard from <= caret, caret <= ns.length else { dismissPanel(); return }
        let query = ns.substring(with: NSRange(location: from, length: caret - from))
        // A space/newline ends the tag/ref — let it stand as literal text.
        if query.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { dismissPanel(); return }
        panel.filter(query: query)
    }

    private func completionItems(for trigger: String) -> [ChatCompletionItem] {
        switch trigger {
        case "#":
            return tags.map { .note(id: "tag:\($0)", icon: "number", label: $0, section: "Tags", trigger: "#") }
        case "@":
            return references.map {
                .note(id: "ref:\($0.id)", icon: "note.text",
                      label: $0.preview.isEmpty ? "Untitled" : $0.preview,
                      description: $0.time, section: "Notes", trigger: "@")
            }
        default: return []
        }
    }

    private func performSelect(_ item: ChatCompletionItem) {
        guard let tv = textView, let start = triggerLocation else { return }
        let caret = tv.selectedRange().location
        let range = NSRange(location: start, length: max(0, caret - start))
        dismissPanel()
        let token: String
        if item.id.hasPrefix("tag:") {
            token = "#\(item.id.dropFirst(4)) "
        } else if item.id.hasPrefix("ref:") {
            let refId = String(item.id.dropFirst(4))
            token = "[\(refLabel(item.label))](\(NoteLink.href(refId))) "
        } else {
            return
        }
        isProgrammatic = true
        replace(range, with: token, caret: range.location + (token as NSString).length)
        isProgrammatic = false
    }

    /// One clean line of link text — no brackets/newlines that would break the
    /// `[label](url)` Markdown — truncated for a tidy inline reference.
    private func refLabel(_ preview: String) -> String {
        let one = preview.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
        if one.isEmpty { return "note" }
        return one.count > 24 ? String(one.prefix(24)) + "…" : one
    }

    // MARK: Panel geometry (mirrors ChatNSTextView)

    private func composerScreenRect(_ tv: NSTextView) -> NSRect? {
        guard let window = tv.window else { return nil }
        let source: NSView = tv.enclosingScrollView ?? tv
        let onScreen = window.convertToScreen(source.convert(source.bounds, to: nil))
        return NSRect(x: onScreen.minX, y: onScreen.maxY + 8, width: onScreen.width, height: 0)
    }

    private func composerVisibleFrame(_ tv: NSTextView) -> NSRect {
        let screenVisible = (tv.window?.screen ?? NSScreen.main)?.visibleFrame ?? (NSScreen.main?.frame ?? .zero)
        guard let frame = tv.window?.frame else { return screenVisible }
        let clamped = NSIntersectionRect(frame, screenVisible)
        return clamped.isEmpty ? screenVisible : clamped
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
    /// Other notes the `@` panel can reference, and existing `#tags` the `#` panel offers.
    var references: [NoteRef] = []
    var tags: [String] = []
    /// A finished region capture's `file://` URL, inserted as a Markdown image.
    var onPasteImage: ((NSPasteboard) -> String?)? = nil

    var body: some View {
        NativeTextViewWrapper(
            text: $markdown,
            configuration: NoteMarkdownEngine.configuration,
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
        .background(TextViewProbe { controller.attach($0) })
        .onAppear { controller.references = references; controller.tags = tags }
        .onChange(of: references) { _, new in controller.references = new }
        .onChange(of: tags) { _, new in controller.tags = new }
    }
}

// MARK: - NSTextView introspection

/// Captures the engine's underlying editable `NSTextView` so the toolbar and the
/// completion popup can act on the caret/selection. Placed as a `.background` of
/// the editor, it climbs its ancestors one level at a time and, at each level,
/// searches that subtree for the composer's editable text view. Climbing from the
/// probe (which sits right next to the editor) finds the composer's own text view
/// well before reaching the window root — so it never grabs the PDF/chat/search
/// text views elsewhere in the window.
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
