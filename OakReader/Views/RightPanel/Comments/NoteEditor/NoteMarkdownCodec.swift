import AppKit

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
