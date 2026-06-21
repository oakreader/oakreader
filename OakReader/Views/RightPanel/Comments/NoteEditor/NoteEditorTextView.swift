import AppKit

// MARK: - Text view

/// The live editing surface: a TextKit-1 `NSTextView` that holds rich attributes
/// (true WYSIWYG), drives the toolbar commands, and hosts the `@`/`#`/`/`
/// completion panel. Inline `$…$` math live-rendering lives in the `+Math`
/// extension; the `#tag`/quote/code/math *drawing* lives in `NoteTagLayoutManager`.
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

    /// Re-entrancy guard for the math restyle pass (see `NoteEditorTextView+Math`).
    /// `internal` so that extension — in a separate file — can read it.
    var isRestylingMath = false
    /// Cheap (text + selection) fingerprint of the last math pass, so the 2–3 calls
    /// a single command fires — and no-op caret moves — skip the expensive rescan.
    var lastMathSignature = ""

    /// A quote/code block toggled on an *empty* paragraph lives only in
    /// `typingAttributes` — an empty line has no character to hold the `.oakBlock`
    /// attribute. A mouse click into that line makes AppKit reset `typingAttributes`,
    /// silently dropping the block, so the next keystrokes are plain text and Return
    /// "sends the note" instead of extending the block. We remember the pending block
    /// here and re-arm it whenever the caret is back on an empty line, until a real
    /// character anchors it. Lists don't need this — their inserted marker run is a
    /// real character that already carries the block.
    private var pendingEmptyBlock: NoteBlock?

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
        typingAttributes = NoteEditorStyle.defaultTypingAttributes
        handleTextChange()
    }

    // MARK: Change plumbing

    func handleTextChange() {
        restyleMath()
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        onChange?(trimmed.isEmpty, string.count)
        reportHeight()
        // Block decorations (quote/code fills + the code border) are drawn full-width
        // and a few points beyond the glyphs, so AppKit's per-edit glyph-rect
        // invalidation doesn't cover them — a reflow or toggle leaves a stale "ghost"
        // box behind. Force a full repaint so only the current decoration is drawn.
        needsDisplay = true
    }

    private func reportHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        onHeight?(lm.usedRect(for: tc).height + textContainerInset.height * 2)
    }

    /// Re-measure and emit the content height *now*. The initial report from
    /// `setMarkdown` runs inside the representable's `makeNSView`, where a SwiftUI
    /// binding mutation is dropped (the same reason the composer re-seeds
    /// `isEmpty`/`charCount` in `onAppear`). The host defers a call to this after
    /// construction so an existing multi-line note opens grown-to-fit instead of in a
    /// fixed, scrolling box. Mirrors `ChatInputTextView`'s deferred `updateHeight`.
    func reportHeightNow() { reportHeight() }

    override func didChangeText() {
        super.didChangeText()
        handleTextChange()
    }

    // MARK: Key handling + completion triggers

    override func keyDown(with event: NSEvent) {
        // Route to the completion panel first when it's open.
        if completionPanel != nil, handleCompletionKey(event) { return }

        // Return is block-aware. Plain Return is quick-capture (save) in prose, but
        // inside a code block / list / quote it adds or continues a line instead —
        // otherwise a multi-line code block is impossible (the bug this fixes) and a
        // numbered list can never reach item 2. ⌘+Return always saves (the escape
        // hatch from inside a block); ⇧+Return is always a literal newline.
        if event.keyCode == 36 {
            let mods = event.modifierFlags
            if mods.contains(.command) { onSubmit?(); return }
            if mods.contains(.shift) { insertNewline(nil); return }
            switch caretBlock() {
            case .code:
                if caretParagraphIsEmpty() { exitCurrentBlock() } else { insertNewline(nil) }
            case .bullet, .ordered, .quote:
                if caretParagraphIsEmpty() { exitCurrentBlock() } else { continueBlock(caretBlock()) }
            case .paragraph, .h1, .h2, .h3:
                onSubmit?()
            }
            return
        }

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
            // Flatten newlines so a multi-line note renders as ONE row (the panel's
            // `.byTruncatingTail` only clips width — it doesn't collapse `\n`).
            let oneLine = $0.preview
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .note(id: "ref:\($0.id)", icon: "note.text",
                  label: oneLine.isEmpty ? "Untitled" : oneLine,
                  description: $0.time, section: "Notes", trigger: "@",
                  pinnedDescription: true)
        }
        case "#": return tags.map { .note(id: "tag:\($0)", icon: "number", label: $0, section: "Tags", trigger: "#") }
        default: return []
        }
    }

    private static let blockItems: [ChatCompletionItem] = [
        .note(id: "block:heading", icon: "textformat.size", label: "Heading", section: "Format", trigger: "/"),
        .note(id: "block:bullet", icon: "list.bullet", label: "Bulleted list", section: "Format", trigger: "/"),
        .note(id: "block:ordered", icon: "list.number", label: "Numbered list", section: "Format", trigger: "/"),
        // `quote.opening` — matches the toolbar; NOT `text.quote`, which the app
        // reserves for a *source reference* (would read as "make a reference").
        .note(id: "block:quote", icon: "quote.opening", label: "Quote", section: "Format", trigger: "/"),
        .note(id: "block:code", icon: "curlybraces.square", label: "Code block", section: "Format", trigger: "/"),
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
        // No links in literal code (Slack parity).
        guard caretBlock() != .code, !caretInlineCode() else { return }
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
        typingAttributes = NoteEditorStyle.defaultTypingAttributes
    }

    // MARK: Code-context exclusivity (Slack parity)

    /// The block kind at the caret (falls back to typing attributes when empty).
    private func caretBlock() -> NoteBlock {
        if let ts = textStorage, ts.length > 0 {
            let loc = max(0, min(selectedRange().location, ts.length - 1))
            if let raw = ts.attribute(.oakBlock, at: loc, effectiveRange: nil) as? Int,
               let b = NoteBlock(rawValue: raw) { return b }
        }
        if let raw = typingAttributes[.oakBlock] as? Int, let b = NoteBlock(rawValue: raw) { return b }
        return .paragraph
    }

    /// Whether the caret sits inside an inline-code run.
    private func caretInlineCode() -> Bool {
        if let ts = textStorage, ts.length > 0 {
            let loc = max(0, min(selectedRange().location, ts.length - 1))
            return ts.attribute(.oakInlineCode, at: loc, effectiveRange: nil) != nil
        }
        return typingAttributes[.oakInlineCode] != nil
    }

    /// Code is *literal* text, so rich inline formatting doesn't apply in a code
    /// context — Slack's rule, and the reason you can't make "bold code". Bold/
    /// italic/underline/strikethrough are ignored in any code context; inline code
    /// additionally can't be nested inside a code block.
    private func ignoresInCodeContext(_ name: String) -> Bool {
        let rich: Set<String> = ["bold", "italic", "underline", "strikethrough"]
        if caretBlock() == .code { return rich.contains(name) || name == "code" }
        if caretInlineCode() { return rich.contains(name) }
        return false
    }

    // MARK: Formatting commands

    func runCommand(_ name: String) {
        // Slack parity: ignore rich inline formatting while in literal code. Block
        // toggles still run (e.g. pressing Code block again leaves the code block).
        guard !ignoresInCodeContext(name) else { return }
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
        // No selection: toggle inline code at the caret via typing attributes (mirrors
        // bold/italic). Without this you could turn code ON for a selection but never
        // turn it OFF from a collapsed caret — pressing the button did nothing, so text
        // typed onward stayed stuck in code. The pill background is painted by the
        // layout manager off `.oakInlineCode`, so we only flip the marker + font here.
        if sel.length == 0 {
            if typingAttributes[.oakInlineCode] != nil {
                typingAttributes.removeValue(forKey: .oakInlineCode)
                typingAttributes[.font] = NoteEditorStyle.baseFont
            } else {
                typingAttributes[.oakInlineCode] = true
                typingAttributes[.font] = NoteEditorStyle.monoFont
            }
            return
        }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        let isCode = textStorage?.attribute(.oakInlineCode, at: sel.location, effectiveRange: nil) != nil
        if isCode {
            textStorage?.removeAttribute(.oakInlineCode, range: sel)
            textStorage?.addAttribute(.font, value: NoteEditorStyle.baseFont, range: sel)
        } else {
            textStorage?.addAttributes([.oakInlineCode: true, .font: NoteEditorStyle.monoFont], range: sel)
        }
        didChangeText()
    }

    /// Toggle a block kind on the caret's paragraph. Lists also insert/remove a
    /// rendered marker run (`•  ` / `1.  `) since plain NSTextView won't draw one.
    private func toggleBlock(_ block: NoteBlock) {
        guard let ts = textStorage else { return }
        let paraRange = (string as NSString).paragraphRange(for: selectedRange())
        let current = (paraRange.location < ts.length)
            ? ts.attribute(.oakBlock, at: paraRange.location, effectiveRange: nil) as? Int
            : (typingAttributes[.oakBlock] as? Int)
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
        // Continue the block when typing onward (esp. toggled on an empty line).
        typingAttributes = blockTypingAttributes(target)
        // If we toggled a quote/code block onto an empty line, remember it so a click
        // into the (character-less) line doesn't drop the block before the user types.
        pendingEmptyBlock = (target != .paragraph && caretParagraphIsEmpty()) ? target : nil
        didChangeText()
    }

    /// Typing attributes matching a block so text typed after a toggle inherits it.
    private func blockTypingAttributes(_ block: NoteBlock) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .paragraphStyle: NoteEditorStyle.paragraphStyle(block),
            .oakBlock: block.rawValue,
            .foregroundColor: NSColor.labelColor,
            .font: NoteEditorStyle.baseFont,
        ]
        switch block {
        case .h1, .h2, .h3: attrs[.font] = NoteEditorStyle.headingFont(block)
        case .code: attrs[.font] = NoteEditorStyle.monoFont   // bg drawn by the layout manager
        case .quote: attrs[.foregroundColor] = NSColor.secondaryLabelColor
        case .paragraph, .bullet, .ordered: break
        }
        return attrs
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

    // MARK: List / block continuation on Return

    /// Whether the caret's paragraph has no content beyond an optional list marker —
    /// the signal that a second Return should leave the list/quote/code block.
    private func caretParagraphIsEmpty() -> Bool {
        let para = (string as NSString).paragraphRange(for: selectedRange())
        var start = para.location, length = para.length
        if let len = leadingMarkerLength(in: para) { start += len; length -= len }
        guard length > 0 else { return true }
        let text = (string as NSString).substring(with: NSRange(location: start, length: length))
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return inside a non-empty list/quote line: open a fresh line that stays in the
    /// block. Lists get a newly rendered marker (`•` / `N.`) since a plain NSTextView
    /// won't draw one; quote/code just carry the block forward via typing attributes.
    private func continueBlock(_ block: NoteBlock) {
        insertNewline(nil)   // the new paragraph inherits the block via typingAttributes
        guard block == .bullet || block == .ordered, let ts = textStorage else {
            typingAttributes = blockTypingAttributes(block)
            pendingEmptyBlock = block   // the fresh quote/code line is empty until typed into
            return
        }
        let loc = selectedRange().location
        let marker = block == .bullet ? "•  " : "\(orderedNumber(at: loc)).  "
        let m = NoteEditorStyle.listMarker(marker)
        guard shouldChangeText(in: NSRange(location: loc, length: 0), replacementString: m.string) else { return }
        ts.replaceCharacters(in: NSRange(location: loc, length: 0), with: m)
        let para = (string as NSString).paragraphRange(for: selectedRange())
        NoteEditorStyle.applyBlock(block, to: ts, range: para)
        typingAttributes = blockTypingAttributes(block)
        didChangeText()
    }

    /// Keep a quote/code block toggled on an empty line alive across the
    /// `typingAttributes` reset a mouse click triggers (see `pendingEmptyBlock`).
    /// Re-arms while the caret sits on the empty block line; clears once a character
    /// anchors the block or the caret moves to a non-empty line.
    private func maintainPendingBlock() {
        guard let pb = pendingEmptyBlock else { return }
        if caretParagraphIsEmpty() {
            if (typingAttributes[.oakBlock] as? Int) != pb.rawValue {
                typingAttributes = blockTypingAttributes(pb)
            }
        } else {
            pendingEmptyBlock = nil
        }
    }

    /// Return on an empty block line: strip any marker and drop back to a plain
    /// paragraph — the standard "Return on an empty bullet exits the list" gesture,
    /// extended to quote and code so the keyboard can always leave the block.
    private func exitCurrentBlock() {
        guard let ts = textStorage else { return }
        var para = (string as NSString).paragraphRange(for: selectedRange())
        if let len = leadingMarkerLength(in: para),
           shouldChangeText(in: NSRange(location: para.location, length: len), replacementString: "") {
            ts.replaceCharacters(in: NSRange(location: para.location, length: len), with: "")
            para = (string as NSString).paragraphRange(for: selectedRange())
        }
        if para.length > 0, shouldChangeText(in: para, replacementString: nil) {
            NoteEditorStyle.applyBlock(.paragraph, to: ts, range: para)
            ts.addAttribute(.font, value: NoteEditorStyle.baseFont, range: para)
            ts.addAttribute(.foregroundColor, value: NSColor.labelColor, range: para)
            ts.removeAttribute(.backgroundColor, range: para)
        }
        typingAttributes = blockTypingAttributes(.paragraph)
        didChangeText()
        reportActiveFormats()
    }

    // MARK: Active-format reporting

    func reportActiveFormats() {
        // A click into an empty quote/code line wipes typingAttributes — re-arm the
        // pending block first so the caret stays "in" the block (selection changes
        // route here, including the one a mouse click fires).
        maintainPendingBlock()
        // Re-fold/unfold math as the caret moves (reveals the source of the run the
        // caret enters, re-renders the one it leaves).
        restyleMath()
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
