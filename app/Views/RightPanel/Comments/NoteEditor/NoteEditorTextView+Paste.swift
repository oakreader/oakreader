import AppKit

// MARK: - Copy and paste (Slack's clipboard module, natively)
//
// Slack's composer ("texty", `getPlainClipboardModule`) never lets pasted
// content bring its own look:
//   - its own copies carry a private, lossless type (`slack/texty`) that wins
//     on paste;
//   - HTML from other apps is cut down to a whitelist of formats
//     (`cleanStyleFromHtmlDelta`: bold, italic, strike, code, link, lists, …);
//   - text pasted into a code block goes in as plain text.
// Before this, the editor accepted RTF/HTML as-is: a web page pasted Georgia
// 30 pt in red next to the system font, styling the toolbar could not clear.

extension NSPasteboard.PasteboardType {
    /// A note's own copy: the selection as note markdown, lossless between notes.
    static let oakNoteMarkdown = NSPasteboard.PasteboardType("com.oakreader.note-markdown")
}

extension NoteEditorTextView {

    // MARK: Copy

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let wrote = super.writeSelection(to: pboard, types: types)
        let sel = selectedRange()
        guard wrote, sel.length > 0, let ts = textStorage, NSMaxRange(sel) <= ts.length else { return wrote }
        let markdown = NoteMarkdownCodec.markdown(from: ts.attributedSubstring(from: sel))
        pboard.addTypes([.oakNoteMarkdown], owner: nil)
        pboard.setString(markdown, forType: .oakNoteMarkdown)
        return wrote
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes + [.oakNoteMarkdown]
    }

    // MARK: Paste

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.oakNoteMarkdown] + super.readablePasteboardTypes
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let content = sanitizedPaste(from: pboard) else { return super.readSelection(from: pboard) }
        insertPasted(content)
        return true
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        readSelection(from: pboard)
    }

    /// ⌘⇧V / ⌥⇧⌘V: the text exactly as copied, no conversion — the escape hatch
    /// when automatic markdown conversion guesses wrong.
    override func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertPasted(plainRun(text))
    }

    /// What a paste inserts, already in the editor's own attributes.
    func sanitizedPaste(from pboard: NSPasteboard) -> NSAttributedString? {
        // Literal code takes literal text, whatever the source offers.
        if caretBlock() == .code {
            return pboard.string(forType: .string).map(plainRun)
        }
        // A note's own copy round-trips exactly.
        if let markdown = pboard.string(forType: .oakNoteMarkdown) {
            return NoteMarkdownCodec.attributed(markdown)
        }
        // Rich content from another app: keep only what a note can express.
        let richTypes: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .html]
        if pboard.availableType(from: richTypes) != nil,
           let rich = pboard.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString {
            return whitelisted(rich)
        }
        // Plain text: markdown becomes formatting, anything else stays plain.
        if let text = pboard.string(forType: .string) {
            return Self.looksLikeMarkdown(text) ? NoteMarkdownCodec.attributed(text) : plainRun(text)
        }
        return nil
    }

    /// Slack's `hasAnyMarkdown` / `hasComplexMarkdown`, on line starts and spans.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        let patterns = [
            #"(?m)^\s{0,3}(#{1,3}\s|[-*+]\s|\d+\.\s|>\s|```)"#,   // block prefixes
            #"\*\*[^*\n]+\*\*"#, #"(?<![\w*])\*[^*\s][^*\n]*\*(?!\w)"#,   // bold, italic
            #"~~[^~\n]+~~"#, #"`[^`\n]+`"#, #"\[[^\]\n]+\]\([^)\s]+\)"#,   // strike, code, link
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    func plainRun(_ text: String) -> NSAttributedString {
        // Slack's plain paste also drops trailing spaces on each line.
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        return NSAttributedString(string: cleaned, attributes: blockTypingAttributes(caretBlock()))
    }

    /// Rebuild rich text from scratch in the editor's attributes, carrying over
    /// only bold, italic, strikethrough, monospace (as inline code), safe links
    /// and lists — Slack's paste whitelist, minus what notes do not have.
    func whitelisted(_ rich: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ns = rich.string as NSString
        var location = 0
        var first = true
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(para)
            var body = para
            // Drop the paragraph's own newline; paragraphs are rejoined below.
            while body.length > 0, let scalar = Unicode.Scalar(ns.character(at: NSMaxRange(body) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                body.length -= 1
            }

            let style = rich.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            var block: NoteBlock = .paragraph
            if let list = style?.textLists.last {
                let format = list.markerFormat.rawValue
                block = (format.contains("decimal") || format.contains("roman") || format.contains("alpha")) ? .ordered : .bullet
                // HTML import writes the marker as text ("\t•\t", "\t1.\t"): drop it.
                let text = ns.substring(with: body) as NSString
                let marker = text.range(of: #"^\t?[^\t\n]{0,6}\t"#, options: .regularExpression)
                if marker.location != NSNotFound {
                    body = NSRange(location: body.location + marker.length, length: body.length - marker.length)
                }
            }

            if !first { out.append(NSAttributedString(string: "\n", attributes: blockTypingAttributes(.paragraph))) }
            first = false
            let lineStart = out.length
            if block == .bullet || block == .ordered {
                out.append(NoteEditorStyle.listMarker(block == .bullet ? "•  " : "1.  "))
            }
            let base = blockTypingAttributes(block)
            rich.enumerateAttributes(in: body, options: []) { attrs, range, _ in
                var a = base
                if let font = attrs[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(.monoSpace) {
                        a[.font] = NoteEditorStyle.monoFont
                        a[.oakInlineCode] = true
                    } else {
                        var f = NoteEditorStyle.baseFont
                        if traits.contains(.bold) { f = f.withToggledTrait(.bold, on: true) }
                        if traits.contains(.italic) { f = f.withToggledTrait(.italic, on: true) }
                        a[.font] = f
                    }
                }
                if attrs[.strikethroughStyle] != nil { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let url = Self.safeLink(attrs[.link]), a[.oakInlineCode] == nil {
                    let font = a[.font]
                    a.merge(linkAttributes(url)) { _, new in new }
                    a[.font] = font
                }
                out.append(NSAttributedString(string: ns.substring(with: range), attributes: a))
            }
            if block != .paragraph {
                let line = NSRange(location: lineStart, length: out.length - lineStart)
                NoteEditorStyle.applyBlock(block, to: out, range: line)
            }
        }
        return out
    }

    /// Only links a reader can follow safely: Slack turns `javascript:` and
    /// malformed URLs into plain text.
    static func safeLink(_ value: Any?) -> String? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url.absoluteString
    }

    /// Replace the selection with `content` as one undoable edit.
    func insertPasted(_ content: NSAttributedString) {
        guard let ts = textStorage else { return }
        let sel = selectedRange()
        guard shouldChangeText(in: sel, replacementString: content.string) else { return }
        ts.replaceCharacters(in: sel, with: content)
        setSelectedRange(NSRange(location: sel.location + content.length, length: 0))
        pendingEmptyBlock = nil
        typingAttributes = blockTypingAttributes(caretBlock())
        didChangeText()
        reportActiveFormats()
        scrollRangeToVisible(selectedRange())
    }
}
