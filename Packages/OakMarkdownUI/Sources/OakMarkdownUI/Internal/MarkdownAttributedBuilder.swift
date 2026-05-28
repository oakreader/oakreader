import AppKit
import Markdown
import SwiftMath

/// Converts a markdown prose block's `swift-markdown` AST into an `NSAttributedString`,
/// the same approach Dia uses (`MarkupVisitor` → NSAttributedString). Handles headings,
/// paragraphs, emphasis/strong, inline code, links, lists, blockquotes, breaks.
/// Inline `$…$` math attachments are layered on in a later pass (not here).
struct MarkdownAttributedBuilder: MarkupVisitor {
    typealias Result = NSAttributedString

    let theme: MarkdownTheme
    private var listDepth = 0

    static func attributedString(for markdown: String, theme: MarkdownTheme) -> NSAttributedString {
        var builder = MarkdownAttributedBuilder(theme: theme)
        let document = Document(parsing: markdown)
        return builder.visit(document)
    }

    // MARK: base attributes

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: theme.bodyFont, .foregroundColor: theme.textColor]
    }

    private func bodyParagraphStyle(headIndent: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = theme.bodyLineHeightMultiple
        p.paragraphSpacing = theme.paragraphSpacing
        p.firstLineHeadIndent = headIndent
        p.headIndent = headIndent
        return p
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, to attr: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let f = (value as? NSFont) ?? theme.bodyFont
            let desc = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(trait))
            if let nf = NSFont(descriptor: desc, size: f.pointSize) {
                m.addAttribute(.font, value: nf, range: range)
            }
        }
        return m
    }

    private func applyParagraphStyle(_ style: NSParagraphStyle, to attr: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        return m
    }

    // MARK: visitor

    mutating func defaultVisit(_ markup: Markup) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in markup.children { out.append(visit(child)) }
        return out
    }

    mutating func visitDocument(_ document: Document) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let children = Array(document.children)
        for (i, child) in children.enumerated() {
            out.append(visit(child))
            if i < children.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    mutating func visitText(_ text: Text) -> NSAttributedString {
        Self.renderInlineMath(in: text.string, theme: theme)
    }

    // MARK: inline math ($…$)

    // swift-markdown doesn't parse `$…$`, so it arrives as literal Text. Scan it and
    // swap each closed inline-math span for an MTMathImage attachment (SwiftMath, = Dia).
    // Unclosed `$…` during streaming simply stays literal until the closing `$` arrives.
    private static let inlineMathRegex = try! NSRegularExpression(
        pattern: #"(?<!\$)\$(?!\$)([^$\n]+?)\$(?!\$)"#
    )

    static func renderInlineMath(in string: String, theme: MarkdownTheme) -> NSAttributedString {
        let ns = string as NSString
        let base: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .foregroundColor: theme.textColor]
        guard ns.length > 0 else { return NSAttributedString(string: string, attributes: base) }
        let matches = inlineMathRegex.matches(in: string, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return NSAttributedString(string: string, attributes: base) }

        let out = NSMutableAttributedString()
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                out.append(NSAttributedString(
                    string: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)),
                    attributes: base))
            }
            let latex = ns.substring(with: m.range(at: 1))
            if let attachment = mathAttachment(latex: latex, theme: theme) {
                out.append(attachment)
            } else {
                out.append(NSAttributedString(string: ns.substring(with: m.range), attributes: base))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: cursor), attributes: base))
        }
        return out
    }

    static func mathAttachment(latex: String, theme: MarkdownTheme) -> NSAttributedString? {
        let mathImage = MTMathImage(
            latex: latex, fontSize: theme.bodyFont.pointSize,
            textColor: theme.textColor, labelMode: .text
        )
        let (error, image) = mathImage.asImage()
        guard error == nil, let image else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Approx baseline-align: center the glyph image around the text's cap region.
        let y = (theme.bodyFont.capHeight - image.size.height) / 2
        attachment.bounds = CGRect(x: 0, y: y, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
        NSAttributedString(string: " ", attributes: baseAttributes())
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: baseAttributes())
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        let inline = defaultVisit(paragraph)
        return applyParagraphStyle(bodyParagraphStyle(), to: inline)
    }

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        let inline = defaultVisit(heading)
        let m = NSMutableAttributedString(attributedString: inline)
        let full = NSRange(location: 0, length: m.length)
        let idx = min(max(heading.level, 1), theme.headingSizes.count) - 1
        let size = theme.headingSizes[idx]
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        m.addAttribute(.font, value: font, range: full)
        let p = bodyParagraphStyle()
        p.paragraphSpacingBefore = theme.paragraphSpacing * 0.5
        m.addAttribute(.paragraphStyle, value: p, range: full)
        return m
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        addTrait(.bold, to: defaultVisit(strong))
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        addTrait(.italic, to: defaultVisit(emphasis))
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: defaultVisit(strikethrough))
        m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                       range: NSRange(location: 0, length: m.length))
        return m
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        NSAttributedString(string: inlineCode.code, attributes: [
            .font: theme.codeFont,
            .foregroundColor: theme.textColor,
            .backgroundColor: theme.inlineCodeBackground,
        ])
    }

    mutating func visitLink(_ link: Link) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: defaultVisit(link))
        let full = NSRange(location: 0, length: m.length)
        if let dest = link.destination, let url = URL(string: dest) {
            m.addAttribute(.link, value: url, range: full)
        }
        m.addAttribute(.foregroundColor, value: theme.linkColor, range: full)
        m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: full)
        return m
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> NSAttributedString {
        listDepth += 1
        defer { listDepth -= 1 }
        let out = NSMutableAttributedString()
        let items = Array(unorderedList.listItems)
        for (i, item) in items.enumerated() {
            out.append(renderListItem(item, marker: "•  "))
            if i < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> NSAttributedString {
        listDepth += 1
        defer { listDepth -= 1 }
        let out = NSMutableAttributedString()
        let items = Array(orderedList.listItems)
        let start = Int(orderedList.startIndex)
        for (i, item) in items.enumerated() {
            out.append(renderListItem(item, marker: "\(start + i).  "))
            if i < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private mutating func renderListItem(_ item: ListItem, marker: String) -> NSAttributedString {
        let indent = CGFloat(listDepth) * 18
        let content = defaultVisit(item)
        let line = NSMutableAttributedString(string: marker, attributes: baseAttributes())
        line.append(content)
        let p = bodyParagraphStyle(headIndent: indent + 18)
        p.firstLineHeadIndent = indent
        p.paragraphSpacing = theme.paragraphSpacing * 0.3
        return applyParagraphStyle(p, to: line)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        let inner = defaultVisit(blockQuote)
        let m = NSMutableAttributedString(attributedString: inner)
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: full)
        let p = bodyParagraphStyle(headIndent: 16)
        m.addAttribute(.paragraphStyle, value: p, range: full)
        return m
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
        NSAttributedString(string: "—————", attributes: [
            .font: theme.bodyFont, .foregroundColor: theme.secondaryTextColor,
        ])
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        // Defensive: fenced code is normally routed to CodeBlockView by the splitter.
        NSAttributedString(string: codeBlock.code, attributes: [
            .font: theme.codeFont, .foregroundColor: theme.textColor,
        ])
    }
}
