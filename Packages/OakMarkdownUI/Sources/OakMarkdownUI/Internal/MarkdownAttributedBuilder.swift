import AppKit
import SwiftUI
import CMarkGFM
import SwiftUIMath

/// Converts a markdown prose block into an `NSAttributedString` by walking the
/// cmark-gfm AST (same parser the app already ships — no new dependency). Handles
/// headings, paragraphs, emphasis/strong, inline code, links, lists, blockquotes,
/// breaks; inline `$…$` becomes a SwiftUIMath image attachment.
/// (Fenced code & display math are split out upstream into their own block views.)
@MainActor
enum MarkdownAttributedBuilder {
    typealias Node = UnsafeMutablePointer<cmark_node>

    static func attributedString(for markdown: String, theme: MarkdownTheme) -> NSAttributedString {
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
            return NSAttributedString(string: markdown, attributes: baseAttributes(theme))
        }
        defer { cmark_parser_free(parser) }
        let bytes = Array(markdown.utf8)
        cmark_parser_feed(parser, bytes, bytes.count)
        guard let document = cmark_parser_finish(parser) else {
            return NSAttributedString(string: markdown, attributes: baseAttributes(theme))
        }
        defer { cmark_node_free(document) }
        let renderer = Renderer(theme: theme)
        return renderer.renderBlocks(document)
    }

    // MARK: shared attributes

    static func baseAttributes(_ theme: MarkdownTheme) -> [NSAttributedString.Key: Any] {
        [.font: theme.bodyFont, .foregroundColor: theme.textColor]
    }

    // MARK: inline math ($…$) — cmark doesn't parse it, so scan TEXT literals

    private static let inlineMathRegex = try! NSRegularExpression(
        pattern: #"(?<!\$)\$(?!\$)([^$\n]+?)\$(?!\$)"#
    )

    static func renderInlineMath(in string: String, theme: MarkdownTheme) -> NSAttributedString {
        let ns = string as NSString
        let base = baseAttributes(theme)
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

    // Cache rendered math by (latex|size) so a streaming tail doesn't re-render the
    // same formula every commit.
    private static var imageCache: [String: NSImage] = [:]

    static func mathAttachment(latex: String, theme: MarkdownTheme) -> NSAttributedString? {
        let size = theme.bodyFont.pointSize
        let key = "\(latex)|\(size)"
        let image: NSImage
        if let cached = imageCache[key] {
            image = cached
        } else {
            let view = Math(latex)
                .mathFont(.init(name: .latinModern, size: size))
                .foregroundStyle(Color(nsColor: theme.textColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            guard let rendered = renderer.nsImage else { return nil }
            imageCache[key] = rendered
            image = rendered
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let y = (theme.bodyFont.capHeight - image.size.height) / 2
        attachment.bounds = CGRect(x: 0, y: y, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}

// MARK: - cmark walk

@MainActor
private final class Renderer {
    let theme: MarkdownTheme
    private var listDepth = 0

    init(theme: MarkdownTheme) { self.theme = theme }

    private func children(_ node: MarkdownAttributedBuilder.Node) -> [MarkdownAttributedBuilder.Node] {
        var result: [MarkdownAttributedBuilder.Node] = []
        var child = cmark_node_first_child(node)
        while let current = child {
            result.append(current)
            child = cmark_node_next(current)
        }
        return result
    }

    private func literal(_ node: MarkdownAttributedBuilder.Node) -> String {
        guard let pointer = cmark_node_get_literal(node) else { return "" }
        return String(cString: pointer)
    }

    /// Render a node's block-level children, joined by newlines.
    func renderBlocks(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        let blocks = children(node)
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            out.append(render(block))
            if i < blocks.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private func renderInline(_ node: MarkdownAttributedBuilder.Node) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for child in children(node) { out.append(render(child)) }
        return out
    }

    private func render(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        switch cmark_node_get_type(node) {
        case CMARK_NODE_TEXT:
            return MarkdownAttributedBuilder.renderInlineMath(in: literal(node), theme: theme)
        case CMARK_NODE_SOFTBREAK:
            return NSAttributedString(string: " ", attributes: base())
        case CMARK_NODE_LINEBREAK:
            return NSAttributedString(string: "\n", attributes: base())
        case CMARK_NODE_PARAGRAPH:
            return paragraphStyled(renderInline(node), style: bodyParagraphStyle())
        case CMARK_NODE_HEADING:
            return heading(node)
        case CMARK_NODE_EMPH:
            return addTrait(.italic, to: renderInline(node))
        case CMARK_NODE_STRONG:
            // Explicit .medium (500) reads lighter than the `.bold` symbolic trait,
            // which SF resolves to ~semibold/bold (600–700) — too heavy at body size.
            return addWeight(.medium, to: renderInline(node))
        case CMARK_NODE_CODE:
            return NSAttributedString(string: literal(node), attributes: [
                .font: theme.codeFont,
                .foregroundColor: theme.textColor,
                .backgroundColor: theme.inlineCodeBackground,
                .inlineCodePill: true,
            ])
        case CMARK_NODE_LINK:
            return link(node)
        case CMARK_NODE_IMAGE:
            return image(node)
        case CMARK_NODE_LIST:
            return list(node)
        case CMARK_NODE_ITEM:
            return renderInline(node)
        case CMARK_NODE_BLOCK_QUOTE:
            return blockQuote(node)
        case CMARK_NODE_THEMATIC_BREAK:
            return NSAttributedString(string: "—————", attributes: [
                .font: theme.bodyFont, .foregroundColor: theme.secondaryTextColor,
            ])
        case CMARK_NODE_CODE_BLOCK:
            return NSAttributedString(string: literal(node), attributes: [
                .font: theme.codeFont, .foregroundColor: theme.textColor,
            ])
        default:
            // HTML, images, unknown → fall back to the node's inline children / literal.
            let inline = renderInline(node)
            return inline.length > 0 ? inline : NSAttributedString(string: literal(node), attributes: base())
        }
    }

    // MARK: helpers

    private func base() -> [NSAttributedString.Key: Any] {
        MarkdownAttributedBuilder.baseAttributes(theme)
    }

    private func bodyParagraphStyle(headIndent: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        // minimumLineHeight (not maximum) gives a consistent fixed line height for
        // body text while still letting a line grow for tall inline math / glyphs.
        p.minimumLineHeight = theme.bodyLineHeight
        p.paragraphSpacing = theme.paragraphSpacing
        p.firstLineHeadIndent = headIndent
        p.headIndent = headIndent
        return p
    }

    private func paragraphStyled(_ attr: NSAttributedString, style: NSParagraphStyle) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        addInlineCodeSpacing(m)
        return m
    }

    /// Inline-code pills draw their rounded background a few points wider than the
    /// glyphs (see `HuggingLayoutManager`). Without compensation that overshoot eats
    /// the space between a code span and its neighboring words, so text ends up
    /// touching the pill. Re-open that space by kerning the characters immediately
    /// before and after each pill run by the amount the pill overshoots, which
    /// restores a normal single-space gap. Skip newline neighbors.
    private func addInlineCodeSpacing(_ m: NSMutableAttributedString) {
        let ns = m.string as NSString
        let gap = MarkdownInlineCodePill.horizontalPadding
        var pillRanges: [NSRange] = []
        m.enumerateAttribute(.inlineCodePill, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            if value != nil, range.length > 0 { pillRanges.append(range) }
        }
        for range in pillRanges {
            let before = range.location - 1
            if before >= 0, ns.character(at: before) != 10 {
                m.addAttribute(.kern, value: gap, range: NSRange(location: before, length: 1))
            }
            let after = range.location + range.length
            if after < ns.length, ns.character(at: after) != 10 {
                m.addAttribute(.kern, value: gap, range: NSRange(location: after, length: 1))
            }
        }
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, to attr: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            let f = (value as? NSFont) ?? theme.bodyFont
            let desc = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(trait))
            if let nf = NSFont(descriptor: desc, size: f.pointSize) {
                m.addAttribute(.font, value: nf, range: range)
            }
        }
        return m
    }

    /// Applies an explicit font weight while preserving any non-bold symbolic traits
    /// already on each run (e.g. italic for `***both***`). Used for strong/bold so we
    /// get a controlled medium weight rather than SF's heavy `.bold` trait.
    private func addWeight(_ weight: NSFont.Weight, to attr: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            let f = (value as? NSFont) ?? theme.bodyFont
            var desc = NSFont.systemFont(ofSize: f.pointSize, weight: weight).fontDescriptor
            let symbolic = f.fontDescriptor.symbolicTraits.subtracting(.bold)
            if !symbolic.isEmpty {
                desc = desc.withSymbolicTraits(symbolic)
            }
            if let nf = NSFont(descriptor: desc, size: f.pointSize) {
                m.addAttribute(.font, value: nf, range: range)
            }
        }
        return m
    }

    private func heading(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: renderInline(node))
        let full = NSRange(location: 0, length: m.length)
        let level = Int(cmark_node_get_heading_level(node))
        let idx = min(max(level, 1), theme.headingSizes.count) - 1
        m.addAttribute(.font, value: NSFont.systemFont(ofSize: theme.headingSizes[idx], weight: .semibold), range: full)
        let p = bodyParagraphStyle()
        p.paragraphSpacingBefore = theme.paragraphSpacing * 0.5
        m.addAttribute(.paragraphStyle, value: p, range: full)
        addInlineCodeSpacing(m)
        return m
    }

    // Cache decoded local images by "path|width" so a streaming tail doesn't reload
    // the same file every commit.
    private static var fileImageCache: [String: NSImage] = [:]
    private static let imageMaxWidth: CGFloat = 260

    /// `![alt](url)` — render a *local* image (file URL or absolute path) as a
    /// width-capped attachment. Remote/unloadable images fall back to alt text so
    /// the renderer never blocks on the network.
    private func image(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        func altText() -> NSAttributedString {
            let alt = renderInline(node)
            return alt.length > 0 ? alt : NSAttributedString(string: "🖼", attributes: base())
        }
        guard let urlPtr = cmark_node_get_url(node) else { return altText() }
        let dest = String(cString: urlPtr)
        let maxW = Renderer.imageMaxWidth
        let key = "\(dest)|\(maxW)"

        let loaded: NSImage?
        if let cached = Renderer.fileImageCache[key] {
            loaded = cached
        } else if let url = URL(string: dest), url.isFileURL, let img = NSImage(contentsOf: url) {
            loaded = img
            Renderer.fileImageCache[key] = img
        } else if dest.hasPrefix("/"), let img = NSImage(contentsOfFile: dest) {
            loaded = img
            Renderer.fileImageCache[key] = img
        } else {
            loaded = nil
        }
        guard let img = loaded, img.size.width > 0, img.size.height > 0 else { return altText() }

        var size = img.size
        if size.width > maxW {
            size = CGSize(width: maxW, height: (size.height * maxW / size.width).rounded())
        }
        let attachment = NSTextAttachment()
        attachment.image = img
        attachment.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let m = NSMutableAttributedString(attachment: attachment)
        m.addAttribute(.paragraphStyle, value: bodyParagraphStyle(), range: NSRange(location: 0, length: m.length))
        return m
    }

    private func link(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: renderInline(node))
        let full = NSRange(location: 0, length: m.length)
        if let urlPtr = cmark_node_get_url(node) {
            let dest = String(cString: urlPtr)
            if let url = URL(string: dest) { m.addAttribute(.link, value: url, range: full) }
        }
        m.addAttribute(.foregroundColor, value: theme.linkColor, range: full)
        m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: full)
        return m
    }

    private func list(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        listDepth += 1
        defer { listDepth -= 1 }
        let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        let start = Int(cmark_node_get_list_start(node))
        let items = children(node)
        let out = NSMutableAttributedString()
        // `listDepth` is 1 at the top level, so the marker indent must be measured
        // from depth-1 — otherwise even a top-level list pushes its `1.`/`•` marker
        // a full step (18pt) off the left edge.
        let indent = CGFloat(listDepth - 1) * 18
        for (i, item) in items.enumerated() {
            let marker = ordered ? "\(start + i).  " : "•  "
            let line = NSMutableAttributedString(string: marker, attributes: base())
            line.append(renderInline(item))
            let p = bodyParagraphStyle(headIndent: indent + 18)
            p.firstLineHeadIndent = indent
            p.paragraphSpacing = theme.paragraphSpacing * 0.3
            out.append(paragraphStyled(line, style: p))
            if i < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private func blockQuote(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: renderBlocks(node))
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: full)
        m.addAttribute(.paragraphStyle, value: bodyParagraphStyle(headIndent: 12), range: full)
        // Tag the range so `HuggingLayoutManager` paints a soft rounded fill behind
        // it (the drawing can't be expressed as text attributes). No left bar — the
        // fill alone reads as a quote; the bar on top of it was redundant chrome.
        m.addAttribute(.blockquoteFill, value: theme.blockquoteBackground, range: full)
        return m
    }
}
