import SwiftUI
import AppKit

// MARK: - Attribute keys & block model

extension NSAttributedString.Key {
    /// Marks an inline-code run (so serialization emits `` `…` `` and styling
    /// applies the mono look). A bool flag.
    static let oakInlineCode = NSAttributedString.Key("oakInlineCode")
    /// Marks a `#tag` run (value: the tag name without `#`).
    static let oakTag = NSAttributedString.Key("oakTag")
    /// Paragraph-level block kind (value: `NoteBlock.rawValue`). Applied across a
    /// whole paragraph so serialization can re-emit the right prefix/fence.
    static let oakBlock = NSAttributedString.Key("oakBlock")
    /// A list-item marker run (`•  ` / `1.  `) drawn as real text but skipped on
    /// serialization — `NSTextList` markers don't render in a plain TextKit-2
    /// NSTextView, so we render the marker ourselves and strip it when saving.
    static let oakListMarker = NSAttributedString.Key("oakListMarker")
}

/// Paragraph-level block types the editor round-trips with Markdown.
enum NoteBlock: Int {
    case paragraph = 0, h1, h2, h3, bullet, ordered, quote, code
}

// MARK: - Styling constants

enum NoteEditorStyle {
    static let baseFont = NSFont.systemFont(ofSize: 14)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static var accent: NSColor { .controlAccentColor }
    static var codeBackground: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.10) }
    // Match the card's `NoteTagChip`: neutral grey, NOT accent — secondary text on
    // a light grey fill (a chip-like token, kept consistent editor ↔ review).
    static var tagForeground: NSColor { .secondaryLabelColor }
    static var tagBackground: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.12) }

    static func headingFont(_ block: NoteBlock) -> NSFont {
        switch block {
        case .h1: return .systemFont(ofSize: 20, weight: .semibold)
        case .h2: return .systemFont(ofSize: 17, weight: .semibold)
        default:  return .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    static func paragraphStyle(_ block: NoteBlock) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
        p.paragraphSpacing = 6
        switch block {
        case .bullet, .ordered:
            // Hanging indent so wrapped lines align past the marker text we render.
            p.headIndent = 22; p.firstLineHeadIndent = 0
        case .quote:
            p.headIndent = 14; p.firstLineHeadIndent = 14
        case .code:
            p.headIndent = 8; p.firstLineHeadIndent = 8
        default:
            break
        }
        return p
    }

    /// A list-item marker run (`•  ` / `1.  `) — real text, but tagged so it's
    /// skipped on serialization and re-derived from the block kind.
    static func listMarker(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: baseFont, .foregroundColor: NSColor.secondaryLabelColor, .oakListMarker: true,
        ])
    }

    /// Apply a block's paragraph attributes over `range` of a mutable string.
    static func applyBlock(_ block: NoteBlock, to ts: NSMutableAttributedString, range: NSRange) {
        guard range.length >= 0 else { return }
        ts.addAttribute(.oakBlock, value: block.rawValue, range: range)
        ts.addAttribute(.paragraphStyle, value: paragraphStyle(block), range: range)
        switch block {
        case .h1, .h2, .h3:
            ts.addAttribute(.font, value: headingFont(block), range: range)
        case .code:
            ts.addAttribute(.font, value: monoFont, range: range)
            ts.addAttribute(.backgroundColor, value: codeBackground, range: range)
        case .quote:
            ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        default:
            break
        }
    }
}

private extension NSFont {
    func withToggledTrait(_ trait: NSFontDescriptor.SymbolicTraits, on: Bool) -> NSFont {
        var traits = fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        let desc = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: pointSize) ?? self
    }
    var hasBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var hasItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }
}

// MARK: - Markdown ⇄ NSAttributedString

/// The two-way bridge that makes the editor a *true* WYSIWYG surface: the buffer
/// holds real attributes (bold is a bold font, not `**`), and we (de)serialize to
/// Markdown only at load/save — so storage stays Markdown while the input never
/// shows a marker.
enum NoteMarkdownCodec {

    // MARK: Markdown → Attributed

    static func attributed(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = md.components(separatedBy: "\n")
        var i = 0
        var first = true
        var orderedNum = 0

        func append(_ inline: NSAttributedString, block: NoteBlock) {
            if !first { out.append(NSAttributedString(string: "\n")) }
            first = false
            let start = out.length
            out.append(inline)
            NoteEditorStyle.applyBlock(block, to: out, range: NSRange(location: start, length: out.length - start))
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }   // closing fence
                append(NSAttributedString(string: code.joined(separator: "\n"),
                                          attributes: [.font: NoteEditorStyle.monoFont]),
                       block: .code)
                continue
            }
            func listLine(_ marker: String, _ rest: String, _ block: NoteBlock) -> NSAttributedString {
                let m = NSMutableAttributedString(attributedString: NoteEditorStyle.listMarker(marker))
                m.append(parseInline(rest))
                return m
            }

            if let r = raw.range(of: #"^(#{1,3})\s+"#, options: .regularExpression) {
                let level = raw[r].filter { $0 == "#" }.count
                let block: NoteBlock = level == 1 ? .h1 : (level == 2 ? .h2 : .h3)
                append(parseInline(String(raw[r.upperBound...])), block: block)
                orderedNum = 0
            } else if let r = raw.range(of: #"^>\s?"#, options: .regularExpression) {
                append(parseInline(String(raw[r.upperBound...])), block: .quote)
                orderedNum = 0
            } else if let r = raw.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) {
                append(listLine("•  ", String(raw[r.upperBound...]), .bullet), block: .bullet)
                orderedNum = 0
            } else if let r = raw.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
                orderedNum += 1
                append(listLine("\(orderedNum).  ", String(raw[r.upperBound...]), .ordered), block: .ordered)
            } else {
                append(parseInline(raw), block: .paragraph)
                orderedNum = 0
            }
            i += 1
        }
        return out
    }

    // MARK: Inline parsing

    private enum Inline { case link, code, bold, strike, underline, italicStar, italicUnder, tag }

    private static let inlineSpecs: [(re: NSRegularExpression, kind: Inline)] = {
        func re(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p) }
        let raw: [(NSRegularExpression?, Inline)] = [
            (re(#"\[([^\]]+)\]\(([^)\s]+)\)"#), .link),
            (re(#"`([^`\n]+)`"#), .code),
            (re(#"\*\*([^*\n]+?)\*\*"#), .bold),
            (re(#"~~([^~\n]+?)~~"#), .strike),
            (re(#"<u>(.+?)</u>"#), .underline),
            (re(#"(?<![\*])\*([^*\n]+?)\*(?![\*])"#), .italicStar),
            (re(#"(?<![\w_])_([^_\n]+?)_(?![\w_])"#), .italicUnder),
            (re(#"(?<![\w#])#([\p{L}0-9_\-]+)"#), .tag),
        ]
        return raw.compactMap { item in item.0.map { (re: $0, kind: item.1) } }
    }()

    private static func parseInline(_ text: String) -> NSAttributedString {
        if text.isEmpty { return NSAttributedString(string: "", attributes: [.font: NoteEditorStyle.baseFont]) }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var best: (m: NSTextCheckingResult, kind: Inline)?
        for spec in inlineSpecs {
            if let m = spec.re.firstMatch(in: text, range: full),
               best == nil || m.range.location < best!.m.range.location {
                best = (m, spec.kind)
            }
        }
        guard let hit = best else {
            return NSAttributedString(string: text, attributes: [.font: NoteEditorStyle.baseFont])
        }
        let result = NSMutableAttributedString()
        if hit.m.range.location > 0 {
            result.append(NSAttributedString(string: ns.substring(to: hit.m.range.location),
                                             attributes: [.font: NoteEditorStyle.baseFont]))
        }
        result.append(render(hit.kind, hit.m, ns))
        let after = hit.m.range.location + hit.m.range.length
        if after < ns.length {
            result.append(parseInline(ns.substring(from: after)))
        }
        return result
    }

    private static func render(_ kind: Inline, _ m: NSTextCheckingResult, _ ns: NSString) -> NSAttributedString {
        func group(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        switch kind {
        case .link:
            let inner = group(1), url = group(2)
            let a = NSMutableAttributedString(string: inner, attributes: [.font: NoteEditorStyle.baseFont])
            let r = NSRange(location: 0, length: a.length)
            if let u = URL(string: url) { a.addAttribute(.link, value: u, range: r) } else { a.addAttribute(.link, value: url, range: r) }
            a.addAttribute(.foregroundColor, value: NoteEditorStyle.accent, range: r)
            a.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            return a
        case .code:
            return NSAttributedString(string: group(1), attributes: [
                .font: NoteEditorStyle.monoFont,
                .backgroundColor: NoteEditorStyle.codeBackground,
                .oakInlineCode: true,
            ])
        case .tag:
            return NSAttributedString(string: "#" + group(1), attributes: [
                .font: NoteEditorStyle.baseFont,
                .foregroundColor: NoteEditorStyle.tagForeground,
                .oakTag: group(1),
            ])
        case .bold: return addingTrait(.bold, to: parseInline(group(1)))
        case .italicStar, .italicUnder: return addingTrait(.italic, to: parseInline(group(1)))
        case .strike: return adding([.strikethroughStyle: NSUnderlineStyle.single.rawValue], to: parseInline(group(1)))
        case .underline: return adding([.underlineStyle: NSUnderlineStyle.single.rawValue], to: parseInline(group(1)))
        }
    }

    private static func addingTrait(_ trait: NSFontDescriptor.SymbolicTraits, to s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length), options: []) { value, r, _ in
            let f = (value as? NSFont) ?? NoteEditorStyle.baseFont
            m.addAttribute(.font, value: f.withToggledTrait(trait, on: true), range: r)
        }
        return m
    }

    private static func adding(_ attrs: [NSAttributedString.Key: Any], to s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttributes(attrs, range: NSRange(location: 0, length: m.length))
        return m
    }

    // MARK: Attributed → Markdown

    static func markdown(from attr: NSAttributedString) -> String {
        let ns = attr.string as NSString
        guard ns.length > 0 else { return "" }

        var paras: [(range: NSRange, block: NoteBlock)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { _, range, _, _ in
            var block = NoteBlock.paragraph
            if range.length > 0,
               let raw = attr.attribute(.oakBlock, at: range.location, effectiveRange: nil) as? Int,
               let b = NoteBlock(rawValue: raw) {
                block = b
            }
            paras.append((range, block))
        }

        var lines: [String] = []
        var i = 0, orderedN = 0, prevOrdered = false
        while i < paras.count {
            let (range, block) = paras[i]
            if block == .code {
                var code: [String] = []
                while i < paras.count, paras[i].block == .code {
                    code.append(ns.substring(with: paras[i].range)); i += 1
                }
                lines.append("```"); lines.append(contentsOf: code); lines.append("```")
                prevOrdered = false
                continue
            }
            let inline = serializeInline(attr.attributedSubstring(from: range))
            switch block {
            case .h1: lines.append("# " + inline)
            case .h2: lines.append("## " + inline)
            case .h3: lines.append("### " + inline)
            case .bullet: lines.append("- " + inline)
            case .ordered:
                orderedN = prevOrdered ? orderedN + 1 : 1
                lines.append("\(orderedN). " + inline)
            case .quote: lines.append("> " + inline)
            case .paragraph, .code: lines.append(inline)
            }
            prevOrdered = (block == .ordered)
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func serializeInline(_ para: NSAttributedString) -> String {
        let ns = para.string as NSString
        guard ns.length > 0 else { return "" }
        var out = ""
        para.enumerateAttributes(in: NSRange(location: 0, length: ns.length), options: []) { attrs, range, _ in
            let text = ns.substring(with: range)
            if attrs[.oakListMarker] != nil { return }                 // re-derived from the block prefix
            if attrs[.oakTag] != nil { out += text; return }           // already "#tag"
            if attrs[.oakInlineCode] != nil { out += "`\(text)`"; return }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? String(describing: link)
                out += "[\(text)](\(url))"; return
            }
            var pre = "", suf = ""
            if let f = attrs[.font] as? NSFont {
                if f.hasBold { pre += "**"; suf = "**" + suf }
                if f.hasItalic { pre += "*"; suf = "*" + suf }
            }
            if attrs[.strikethroughStyle] != nil { pre += "~~"; suf = "~~" + suf }
            if attrs[.underlineStyle] != nil { pre += "<u>"; suf = "</u>" + suf }
            out += pre + text + suf
        }
        return out
    }
}

// MARK: - Controller

/// Imperative handle the toolbar drives (same surface as before, so `NoteComposerBox`
/// is unchanged apart from the new commands).
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
        // draws rounded `#tag` chips.
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

// MARK: - Layout manager (rounded #tag chips)

/// Draws a padded, rounded-rect background behind every `oakTag` run so an
/// in-editor `#tag` reads as a chip (matching the card's `NoteTagChip`) instead
/// of the flat, tight rectangle `NSAttributedString.backgroundColor` would give.
final class NoteTagLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let ts = textStorage, let container = textContainers.first {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            ts.enumerateAttribute(.oakTag, in: charRange, options: []) { value, range, _ in
                guard value != nil else { return }
                let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                enumerateEnclosingRects(
                    forGlyphRange: gr,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    // Pad horizontally into the surrounding spaces + a hair vertically,
                    // so the fill reads as a chip without changing text layout.
                    let chip = NSRect(x: rect.minX + origin.x - 3, y: rect.minY + origin.y,
                                      width: rect.width + 6, height: rect.height - 1)
                    let path = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)
                    NoteEditorStyle.tagBackground.setFill()
                    path.fill()
                }
            }
        }
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    }
}

// MARK: - Text view

@MainActor
final class NoteEditorTextView: NSTextView {
    enum PickerKind { case mention, tag }

    var onSubmit: (() -> Void)?
    var onChange: ((_ empty: Bool, _ count: Int) -> Void)?
    var onActiveFormats: ((Set<String>) -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    var onCreateTag: ((String) -> Void)?

    /// Data for the completion panel (kept in sync by the representable).
    var references: [NoteRef] = []
    var tags: [String] = []

    /// Active `ChatCompletionPanel` (the same component the chat composer uses) and
    /// the trigger char + its location, so a selection can replace `<trigger><query>`.
    private var completionPanel: ChatCompletionPanel?
    private var triggerChar: String?
    private var triggerLocation: Int?

    func currentAttributedString() -> NSAttributedString { textStorage ?? NSAttributedString() }

    // MARK: Load / serialize

    func setMarkdown(_ md: String) {
        let attr = NoteMarkdownCodec.attributed(md)
        textStorage?.setAttributedString(attr)
        typingAttributes = [.font: NoteEditorStyle.baseFont, .foregroundColor: NSColor.labelColor]
        handleTextChange()
    }

    // MARK: Change plumbing

    func handleTextChange() {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        onChange?(trimmed.isEmpty, string.count)
        reportHeight()
    }

    private func reportHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        onHeight?(lm.usedRect(for: tc).height + textContainerInset.height * 2)
    }

    override func didChangeText() {
        super.didChangeText()
        handleTextChange()
    }

    // MARK: Key handling + completion triggers

    override func keyDown(with event: NSEvent) {
        // Route to the completion panel first when it's open.
        if completionPanel != nil, handleCompletionKey(event) { return }

        if event.keyCode == 36, event.modifierFlags.contains(.command) { onSubmit?(); return }

        // Trigger detection: `/` at a line start (block menu), `@`/`#` at a word
        // boundary. Insert the char first (super), then surface the panel.
        if let chars = event.characters, chars.count == 1, !event.modifierFlags.contains(.command) {
            switch chars.first! {
            case "/" where atLineStart(selectedRange().location):
                super.keyDown(with: event); showPanel(trigger: "/"); return
            case "@" where atWordBoundary(selectedRange().location):
                super.keyDown(with: event); showPanel(trigger: "@"); return
            case "#" where atWordBoundary(selectedRange().location):
                super.keyDown(with: event); showPanel(trigger: "#"); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// Toolbar `#`/`@` buttons: insert the trigger char, then open the panel —
    /// identical to typing it, so selection consumes `<trigger><query>`.
    func requestPicker(_ kind: PickerKind) {
        let ch = kind == .mention ? "@" : "#"
        insertText(ch, replacementRange: selectedRange())
        showPanel(trigger: ch)
    }

    private func atWordBoundary(_ loc: Int) -> Bool {
        guard loc > 0 else { return true }
        let prev = (string as NSString).substring(with: NSRange(location: loc - 1, length: 1))
        return prev == " " || prev == "\n" || prev == "\t"
    }

    private func atLineStart(_ loc: Int) -> Bool {
        guard loc > 0 else { return true }
        let prev = (string as NSString).substring(with: NSRange(location: loc - 1, length: 1))
        return prev == "\n"
    }

    // MARK: Completion panel (reuses the chat composer's ChatCompletionPanel)

    private func showPanel(trigger: String) {
        dismissPanel()
        triggerChar = trigger
        triggerLocation = selectedRange().location - 1   // the trigger char just inserted
        let items = completionItems(for: trigger)
        guard !items.isEmpty || trigger == "#", let rect = composerScreenRect() else { return }
        let panel = ChatCompletionPanel(
            items: items,
            anchorRect: rect,
            screenVisibleFrame: composerVisibleFrame()
        ) { [weak self] item in self?.performSelect(item) }
        completionPanel = panel
        window?.addChildWindow(panel, ordered: .above)
    }

    func dismissPanel() {
        completionPanel?.dismiss()
        completionPanel = nil
        triggerChar = nil
        triggerLocation = nil
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard let start = triggerLocation else { return false }
        switch event.keyCode {
        case 53: dismissPanel(); return true                      // Esc
        case 36, 48:                                              // Enter / Tab
            if let item = completionPanel?.selectedItem { performSelect(item) }
            else if triggerChar == "#" { createTagFromQuery() }
            else { dismissPanel() }
            return true
        case 126: completionPanel?.moveSelection(by: -1); return true   // Up
        case 125: completionPanel?.moveSelection(by: 1); return true    // Down
        case 51:                                                  // Backspace
            if selectedRange().location <= start { dismissPanel(); super.keyDown(with: event); return true }
            super.keyDown(with: event); updateFilter(); return true
        default:
            if let c = event.characters, !c.isEmpty {
                // Space ends a `#` tag (create-from-query); otherwise just filters.
                if c == " ", triggerChar == "#" { createTagFromQuery(); return true }
                super.keyDown(with: event); updateFilter(); return true
            }
            return false
        }
    }

    private func updateFilter() {
        guard let panel = completionPanel, let start = triggerLocation else { return }
        let cur = selectedRange().location
        let from = start + 1
        guard from <= cur, cur <= (textStorage?.length ?? 0) else { dismissPanel(); return }
        panel.filter(query: (string as NSString).substring(with: NSRange(location: from, length: cur - from)))
    }

    private func completionItems(for trigger: String) -> [ChatCompletionItem] {
        switch trigger {
        case "/": return Self.blockItems
        case "@": return references.map {
            .note(id: "ref:\($0.id)", icon: "note.text",
                  label: $0.preview.isEmpty ? "Untitled" : $0.preview,
                  description: $0.time, section: "Notes", trigger: "@")
        }
        case "#": return tags.map { .note(id: "tag:\($0)", icon: "number", label: $0, section: "Tags", trigger: "#") }
        default: return []
        }
    }

    private static let blockItems: [ChatCompletionItem] = [
        .note(id: "block:heading", icon: "textformat.size", label: "Heading", section: "Format", trigger: "/"),
        .note(id: "block:bullet", icon: "list.bullet", label: "Bulleted list", section: "Format", trigger: "/"),
        .note(id: "block:ordered", icon: "list.number", label: "Numbered list", section: "Format", trigger: "/"),
        .note(id: "block:quote", icon: "text.quote", label: "Quote", section: "Format", trigger: "/"),
        .note(id: "block:code", icon: "curlybraces", label: "Code block", section: "Format", trigger: "/"),
    ]

    // MARK: Selection → insert

    private var triggerRange: NSRange {
        let start = triggerLocation ?? selectedRange().location
        return NSRange(location: start, length: max(0, selectedRange().location - start))
    }

    private func performSelect(_ item: ChatCompletionItem) {
        let range = triggerRange
        dismissPanel()
        let id = item.id
        if id.hasPrefix("block:") {
            // Drop the "/query" then toggle the block on this paragraph.
            if shouldChangeText(in: range, replacementString: "") {
                textStorage?.replaceCharacters(in: range, with: "")
                setSelectedRange(NSRange(location: range.location, length: 0))
                didChangeText()
            }
            runCommand(blockCommand(String(id.dropFirst("block:".count))))
        } else if id.hasPrefix("tag:") {
            replace(range, with: tagToken(String(id.dropFirst("tag:".count))))
        } else if id.hasPrefix("ref:") {
            let refId = String(id.dropFirst("ref:".count))
            replace(range, with: referenceToken(label: refLabel(item.label), href: NoteLink.href(refId)))
        }
    }

    private func createTagFromQuery() {
        let range = triggerRange
        let query = (string as NSString).substring(with: range)
            .dropFirst()  // the leading '#'
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
        dismissPanel()
        guard !query.isEmpty else { return }
        if !tags.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) { onCreateTag?(query) }
        replace(range, with: tagToken(query))
    }

    private func blockCommand(_ key: String) -> String {
        switch key {
        case "heading": return "heading"
        case "bullet": return "bulletList"
        case "ordered": return "orderedList"
        case "quote": return "quote"
        case "code": return "codeBlock"
        default: return ""
        }
    }

    private func refLabel(_ preview: String) -> String {
        let one = preview.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
        if one.isEmpty { return "MEMO" }
        return one.count > 24 ? String(one.prefix(24)) + "…" : one
    }

    private func tagToken(_ tag: String) -> NSAttributedString {
        let token = NSMutableAttributedString(string: "#\(tag)", attributes: [
            .font: NoteEditorStyle.baseFont,
            .foregroundColor: NoteEditorStyle.tagForeground,
            .oakTag: tag,
        ])
        token.append(NSAttributedString(string: " ", attributes: [.font: NoteEditorStyle.baseFont, .foregroundColor: NSColor.labelColor]))
        return token
    }

    private func referenceToken(label: String, href: String) -> NSAttributedString {
        let token = NSMutableAttributedString(string: label, attributes: linkAttributes(href))
        token.append(NSAttributedString(string: " ", attributes: [.font: NoteEditorStyle.baseFont, .foregroundColor: NSColor.labelColor]))
        return token
    }

    /// The composer's frame in screen coords, anchoring the panel above the input
    /// (mirrors `ChatNSTextView.composerScreenRect`).
    private func composerScreenRect() -> NSRect? {
        guard let window else { return nil }
        let source: NSView = enclosingScrollView ?? self
        let onScreen = window.convertToScreen(source.convert(source.bounds, to: nil))
        return NSRect(x: onScreen.minX, y: onScreen.maxY + 8, width: onScreen.width, height: 0)
    }

    private func composerVisibleFrame() -> NSRect {
        let screenVisible = (window?.screen ?? NSScreen.main)?.visibleFrame ?? (NSScreen.main?.frame ?? .zero)
        guard let frame = window?.frame else { return screenVisible }
        let clamped = NSIntersectionRect(frame, screenVisible)
        return clamped.isEmpty ? screenVisible : clamped
    }

    /// Turn the current selection (or insert the URL) into a link.
    func applyLink(url: String) {
        let sel = selectedRange()
        if sel.length > 0 {
            if shouldChangeText(in: sel, replacementString: nil) {
                textStorage?.addAttributes(linkAttributes(url), range: sel)
                didChangeText()
            }
        } else {
            let token = NSAttributedString(string: url, attributes: linkAttributes(url))
            replace(sel, with: token)
        }
    }

    private func linkAttributes(_ url: String) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NoteEditorStyle.baseFont,
            .foregroundColor: NoteEditorStyle.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        attrs[.link] = URL(string: url) ?? url
        return attrs
    }

    private func replace(_ range: NSRange, with attr: NSAttributedString) {
        guard shouldChangeText(in: range, replacementString: attr.string) else { return }
        textStorage?.replaceCharacters(in: range, with: attr)
        didChangeText()
        // Reset typing attributes so following text is plain.
        typingAttributes = [.font: NoteEditorStyle.baseFont, .foregroundColor: NSColor.labelColor]
    }

    // MARK: Formatting commands

    func runCommand(_ name: String) {
        switch name {
        case "bold": toggleTrait(.bold)
        case "italic": toggleTrait(.italic)
        case "underline": toggleAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue)
        case "strikethrough": toggleAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue)
        case "code": toggleInlineCode()
        case "heading": toggleBlock(.h2)
        case "bulletList": toggleBlock(.bullet)
        case "orderedList": toggleBlock(.ordered)
        case "quote": toggleBlock(.quote)
        case "codeBlock": toggleBlock(.code)
        default: break
        }
        handleTextChange()
        reportActiveFormats()
    }

    private func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        let sel = selectedRange()
        if sel.length == 0 {
            let f = (typingAttributes[.font] as? NSFont) ?? NoteEditorStyle.baseFont
            typingAttributes[.font] = f.withToggledTrait(trait, on: !f.fontDescriptor.symbolicTraits.contains(trait))
            return
        }
        let on = !traitAppliedThroughout(trait, sel)
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        textStorage?.enumerateAttribute(.font, in: sel, options: []) { value, r, _ in
            let f = (value as? NSFont) ?? NoteEditorStyle.baseFont
            textStorage?.addAttribute(.font, value: f.withToggledTrait(trait, on: on), range: r)
        }
        didChangeText()
    }

    private func traitAppliedThroughout(_ trait: NSFontDescriptor.SymbolicTraits, _ range: NSRange) -> Bool {
        var all = true
        textStorage?.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            let f = (value as? NSFont) ?? NoteEditorStyle.baseFont
            if !f.fontDescriptor.symbolicTraits.contains(trait) { all = false; stop.pointee = true }
        }
        return all
    }

    private func toggleAttribute(_ key: NSAttributedString.Key, value: Any) {
        let sel = selectedRange()
        if sel.length == 0 {
            if typingAttributes[key] == nil { typingAttributes[key] = value } else { typingAttributes.removeValue(forKey: key) }
            return
        }
        let present = textStorage?.attribute(key, at: sel.location, effectiveRange: nil) != nil
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        if present { textStorage?.removeAttribute(key, range: sel) } else { textStorage?.addAttribute(key, value: value, range: sel) }
        didChangeText()
    }

    private func toggleInlineCode() {
        let sel = selectedRange()
        guard sel.length > 0, shouldChangeText(in: sel, replacementString: nil) else { return }
        let isCode = textStorage?.attribute(.oakInlineCode, at: sel.location, effectiveRange: nil) != nil
        if isCode {
            textStorage?.removeAttribute(.oakInlineCode, range: sel)
            textStorage?.removeAttribute(.backgroundColor, range: sel)
            textStorage?.addAttribute(.font, value: NoteEditorStyle.baseFont, range: sel)
        } else {
            textStorage?.addAttributes([.oakInlineCode: true, .font: NoteEditorStyle.monoFont, .backgroundColor: NoteEditorStyle.codeBackground], range: sel)
        }
        didChangeText()
    }

    /// Toggle a block kind on the caret's paragraph. Lists also insert/remove a
    /// rendered marker run (`•  ` / `1.  `) since plain NSTextView won't draw one.
    private func toggleBlock(_ block: NoteBlock) {
        guard let ts = textStorage else { return }
        let paraRange = (string as NSString).paragraphRange(for: selectedRange())
        let current = ts.attribute(.oakBlock, at: paraRange.location, effectiveRange: nil) as? Int
        let target: NoteBlock = (current == block.rawValue) ? .paragraph : block
        guard shouldChangeText(in: paraRange, replacementString: nil) else { return }

        var range = paraRange
        // Strip an existing list marker first.
        if let len = leadingMarkerLength(in: paraRange) {
            ts.replaceCharacters(in: NSRange(location: paraRange.location, length: len), with: "")
            range = NSRange(location: paraRange.location, length: paraRange.length - len)
        }
        // Insert a fresh marker for list targets.
        if target == .bullet || target == .ordered {
            let marker = target == .bullet ? "•  " : "\(orderedNumber(at: range.location)).  "
            let m = NoteEditorStyle.listMarker(marker)
            ts.replaceCharacters(in: NSRange(location: range.location, length: 0), with: m)
            range = NSRange(location: range.location, length: range.length + m.length)
        }

        NoteEditorStyle.applyBlock(target, to: ts, range: range)
        if target == .paragraph {
            ts.addAttribute(.font, value: NoteEditorStyle.baseFont, range: range)
            ts.removeAttribute(.backgroundColor, range: range)
            ts.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        didChangeText()
    }

    /// Length of the `oakListMarker` run at the start of a paragraph, if any.
    private func leadingMarkerLength(in paraRange: NSRange) -> Int? {
        guard let ts = textStorage, paraRange.length > 0,
              ts.attribute(.oakListMarker, at: paraRange.location, effectiveRange: nil) != nil else { return nil }
        var effective = NSRange(location: 0, length: 0)
        _ = ts.attribute(.oakListMarker, at: paraRange.location, longestEffectiveRange: &effective, in: paraRange)
        return effective.length
    }

    /// Number for an ordered item = 1 + count of immediately-preceding ordered paragraphs.
    private func orderedNumber(at location: Int) -> Int {
        guard let ts = textStorage else { return 1 }
        let ns = string as NSString
        var n = 1, loc = location
        while loc > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            guard let b = ts.attribute(.oakBlock, at: prev.location, effectiveRange: nil) as? Int,
                  b == NoteBlock.ordered.rawValue else { break }
            n += 1; loc = prev.location
        }
        return n
    }

    // MARK: Active-format reporting

    func reportActiveFormats() {
        var set = Set<String>()
        let sel = selectedRange()
        let probe: [NSAttributedString.Key: Any]
        if sel.length == 0 {
            probe = typingAttributes
        } else if let ts = textStorage, sel.location < ts.length {
            probe = ts.attributes(at: sel.location, effectiveRange: nil)
        } else {
            probe = typingAttributes
        }
        if let f = probe[.font] as? NSFont {
            if f.hasBold { set.insert("bold") }
            if f.hasItalic { set.insert("italic") }
        }
        if probe[.underlineStyle] != nil, probe[.link] == nil { set.insert("underline") }
        if probe[.strikethroughStyle] != nil { set.insert("strikethrough") }
        if probe[.oakInlineCode] != nil { set.insert("code") }

        if let ts = textStorage, ts.length > 0 {
            let loc = min(selectedRange().location, ts.length - 1)
            if let raw = ts.attribute(.oakBlock, at: max(0, loc), effectiveRange: nil) as? Int, let b = NoteBlock(rawValue: raw) {
                switch b {
                case .bullet: set.insert("bulletList")
                case .ordered: set.insert("orderedList")
                case .quote: set.insert("quote")
                case .code: set.insert("codeBlock")
                case .h1, .h2, .h3: set.insert("heading")
                case .paragraph: break
                }
            }
        }
        onActiveFormats?(set)
    }
}
