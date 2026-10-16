import AppKit
import SwiftUI
import CMarkGFM
import SwiftUIMath

/// Converts a markdown prose block into an `NSAttributedString` by walking the
/// cmark-gfm AST (same parser the app already ships — no new dependency). Handles
/// headings, paragraphs, emphasis/strong, inline code, links, lists, blockquotes,
/// breaks; `$…$` becomes a math image attachment. Math is swapped for tokens before
/// cmark parses (see `MathPlaceholders`), so cmark never reads LaTeX as markdown.
/// (Fenced code & display math are split out upstream into their own block views.)
@MainActor
enum MarkdownAttributedBuilder {
    typealias Node = UnsafeMutablePointer<cmark_node>

    static func attributedString(for markdown: String, theme: MarkdownTheme) -> NSAttributedString {
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
            return NSAttributedString(string: markdown, attributes: baseAttributes(theme))
        }
        defer { cmark_parser_free(parser) }
        // Enable GFM `~~strikethrough~~`. Plain cmark doesn't parse it, so without
        // this the literal `~~` would render — and the note editor's Strikethrough
        // button emits exactly that. Tables are handled by their own block view
        // (TableBlockView), so they're not attached here.
        cmark_gfm_core_extensions_ensure_registered()
        if let strikethrough = cmark_find_syntax_extension("strikethrough") {
            cmark_parser_attach_syntax_extension(parser, strikethrough)
        }
        let (protected, math) = MathPlaceholders.protect(markdown)
        let bytes = Array(MarkdownCompat.shimCJKEmphasis(protected).utf8)
        cmark_parser_feed(parser, bytes, bytes.count)
        guard let document = cmark_parser_finish(parser) else {
            return NSAttributedString(string: markdown, attributes: baseAttributes(theme))
        }
        defer { cmark_node_free(document) }
        let renderer = Renderer(theme: theme, math: math)
        return stripShims(renderer.renderBlocks(document))
    }

    /// Drop the zero-width spaces `MarkdownCompat.shimCJKEmphasis` added, so they
    /// never reach selection, copy, or caret movement.
    private static func stripShims(_ text: NSAttributedString) -> NSAttributedString {
        guard text.string.contains(MarkdownCompat.shim) else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        out.mutableString.replaceOccurrences(
            of: MarkdownCompat.shim, with: "", options: [], range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Render the inline contents of a cmark-gfm `table_cell` node into an attributed
    /// string. The caller (TableBlockView) owns the cmark document — we just walk the
    /// cell's children using the same inline rules used everywhere else.
    static func renderTableCell(_ cellNode: Node, math: [MathSpan], theme: MarkdownTheme) -> NSAttributedString {
        let renderer = Renderer(theme: theme, math: math)
        return stripShims(renderer.renderTableCell(cellNode))
    }

    // MARK: shared attributes

    static func baseAttributes(_ theme: MarkdownTheme) -> [NSAttributedString.Key: Any] {
        [.font: theme.bodyFont, .foregroundColor: theme.textColor]
    }

    // MARK: math

    /// A cmark text literal, with its math tokens drawn as attachments. A formula no
    /// engine can draw, or one still rendering, shows as typed.
    static func renderText(_ literal: String, math: [MathSpan], theme: MarkdownTheme) -> NSAttributedString {
        let base = baseAttributes(theme)
        let pieces = MathPlaceholders.pieces(in: literal, spans: math)
        if case .text(let text) = pieces.first, pieces.count == 1 {
            return NSAttributedString(string: text, attributes: base)
        }
        let out = NSMutableAttributedString()
        for piece in pieces {
            switch piece {
            case .text(let text):
                out.append(NSAttributedString(string: text, attributes: base))
            case .math(let span):
                out.append(mathAttachment(latex: span.latex, display: span.display, theme: theme)
                    ?? NSAttributedString(string: span.source, attributes: base))
            }
        }
        return out
    }

    // Cache rendered math by (latex|size) so a streaming tail doesn't re-render the
    // same formula every commit.
    private static var imageCache: [String: NSImage] = [:]

    /// SwiftUIMath first; KaTeX drawn by WebKit when SwiftUIMath cannot (see `MathRoute`).
    static func mathAttachment(latex: String, display: Bool = false, theme: MarkdownTheme) -> NSAttributedString? {
        let size = theme.bodyFont.pointSize
        let key = "\(display ? "D" : "T")|\(latex)|\(size)"
        let attachment = NSTextAttachment()
        if let cached = imageCache[key] {
            attachment.image = cached
        } else if MathRoute.nativeCanDraw(latex, display: display, fontSize: size) {
            let view = Math(MarkdownCompat.normalizeLaTeX(latex))
                .mathTypesettingStyle(display ? .display : .text)
                .mathFont(.init(name: .latinModern, size: size))
                .foregroundStyle(Color(nsColor: theme.textColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            guard let rendered = renderer.nsImage else { return nil }
            imageCache[key] = rendered
            attachment.image = rendered
        } else {
            guard case .ready(let rendered) = MathMLRenderer.shared.lookup(
                latex: latex, display: display, fontSize: size, color: theme.textColor) else { return nil }
            attachment.image = rendered.image
            attachment.bounds = CGRect(x: 0, y: -rendered.descent,
                                       width: rendered.image.size.width, height: rendered.image.size.height)
            return NSAttributedString(attachment: attachment)
        }
        let image = attachment.image!
        let y = (theme.bodyFont.capHeight - image.size.height) / 2
        attachment.bounds = CGRect(x: 0, y: y, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}

// MARK: - cmark walk

@MainActor
private final class Renderer {
    let theme: MarkdownTheme
    /// Math lifted out before parsing; text literals carry tokens indexing into it.
    let math: [MathSpan]
    private var listDepth = 0
    /// Block-quote nesting, 1 inside the outermost quote. Drives the opacity ladder.
    private var quoteDepth = 0

    init(theme: MarkdownTheme, math: [MathSpan]) {
        self.theme = theme
        self.math = math
    }

    private func children(_ node: MarkdownAttributedBuilder.Node) -> [MarkdownAttributedBuilder.Node] {
        var result: [MarkdownAttributedBuilder.Node] = []
        var child = cmark_node_first_child(node)
        while let current = child {
            result.append(current)
            child = cmark_node_next(current)
        }
        return result
    }

    /// The node's literal with any math put back as typed: right for code and HTML.
    private func literal(_ node: MarkdownAttributedBuilder.Node) -> String {
        MathPlaceholders.restoreSource(rawLiteral(node), spans: math)
    }

    private func rawLiteral(_ node: MarkdownAttributedBuilder.Node) -> String {
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

    /// Walk the inline children of a `table_cell` node — same rules as a paragraph,
    /// but without paragraph-level styling (the caller wraps the result in cell
    /// chrome and applies alignment).
    func renderTableCell(_ cellNode: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        let inline = renderInline(cellNode)
        addInlineCodeSpacing(inline)
        return inline
    }

    private func render(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        switch cmark_node_get_type(node) {
        case CMARK_NODE_TEXT:
            return MarkdownAttributedBuilder.renderText(rawLiteral(node), math: math, theme: theme)
        case CMARK_NODE_SOFTBREAK:
            // A single newline should SHOW as a line break — note/chat content is
            // hand-typed, not hard-wrapped prose, so "what you type is what you see".
            // Standard Markdown collapses a soft break to a space; that surprised
            // users whose notes ran multiple lines together.
            return NSAttributedString(string: "\n", attributes: base())
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
                .inlineCodeStroke: theme.inlineCodeStroke,
                .inlineCodeRadius: NSNumber(value: Double(theme.inlineCodeCornerRadius)),
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
            // GFM strikethrough is an extension node — a runtime-registered type, not
            // a compile-time constant usable in a `case` — so match it by name.
            if let t = cmark_node_get_type_string(node), strcmp(t, "strikethrough") == 0 {
                let m = NSMutableAttributedString(attributedString: renderInline(node))
                m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                               range: NSRange(location: 0, length: m.length))
                return m
            }
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

    /// Pill-drawn runs — inline code and citation chips — paint a rounded background a
    /// few points wider than their glyphs (see `HuggingLayoutManager`). Without
    /// compensation that overshoot eats the space between the pill and its neighboring
    /// words, so text ends up touching it. Re-open that space by kerning the characters
    /// immediately before and after each pill run by the amount it overshoots, which
    /// restores a normal single-space gap. Skip newline neighbors.
    private func addInlineCodeSpacing(_ m: NSMutableAttributedString) {
        addPillSpacing(m, key: .inlineCodePill, gap: MarkdownInlineCodePill.horizontalPadding)
    }

    private func addPillSpacing(_ m: NSMutableAttributedString,
                                key: NSAttributedString.Key, gap: CGFloat) {
        let ns = m.string as NSString
        var pillRanges: [NSRange] = []
        m.enumerateAttribute(key, in: NSRange(location: 0, length: m.length)) { value, range, _ in
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
        // A heading belongs to the text under it: more room above than below.
        p.paragraphSpacingBefore = theme.headingSpacingBefore[min(idx, theme.headingSpacingBefore.count - 1)]
        p.paragraphSpacing = theme.headingSpacingAfter[min(idx, theme.headingSpacingAfter.count - 1)]
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
        } else if let resolved = OakMarkdownImage.urlResolver?(dest), let img = NSImage(contentsOf: resolved) {
            loaded = img
            Renderer.fileImageCache[key] = img
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
        var destination = ""
        if let urlPtr = cmark_node_get_url(node) {
            destination = String(cString: urlPtr)
            if let url = URL(string: destination) { m.addAttribute(.link, value: url, range: full) }
        }

        // An internal reference (`oak:14`) is a jump-to-source marker, not a web
        // link. It is the accent colour and a little heavier, and nothing else:
        // no underline, because the reader is not leaving the app, and no
        // capsule, because a paragraph with six citations in it became a row of
        // buttons rather than a sentence.
        if destination.hasPrefix(StreamingMarkdownSanitizer.internalScheme) {
            // The label is the host's to supply, not the model's — see
            // `MarkdownTheme.citationLabel`. Substituted here, while building,
            // so a streamed citation never flashes the placeholder.
            //
            // The characters are swapped in place rather than a new string
            // built: the run already carries the body font and the link, and
            // rebuilding it would mean restating both.
            if m.string == StreamingMarkdownSanitizer.citationPlaceholder,
               let resolved = theme.citationLabel?(destination) {
                m.mutableString.setString(resolved)
            }
            let range = NSRange(location: 0, length: m.length)
            m.addAttribute(.foregroundColor, value: theme.citationForeground, range: range)
            if let url = URL(string: destination) { m.addAttribute(.link, value: url, range: range) }
            return addWeight(.medium, to: m)
        }

        m.addAttribute(.foregroundColor, value: theme.linkColor, range: full)
        m.addAttribute(.underlineStyle, value: theme.linkUnderlineStyle.rawValue, range: full)
        if let underline = theme.linkUnderlineColor {
            m.addAttribute(.underlineColor, value: underline, range: full)
        }
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
            p.paragraphSpacing = theme.listItemSpacing
            out.append(paragraphStyled(line, style: p))
            if i < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private func blockQuote(_ node: MarkdownAttributedBuilder.Node) -> NSAttributedString {
        quoteDepth += 1
        defer { quoteDepth -= 1 }
        let m = NSMutableAttributedString(attributedString: renderBlocks(node))
        let full = NSRange(location: 0, length: m.length)
        // One step dimmer per nesting level, never past the floor. Dia calls the
        // floor `quoteLevelMinOpacity`; without one, a quote inside a quote inside a
        // quote is unreadable, and with no ladder at all the nesting is invisible.
        let step = pow(0.8, CGFloat(quoteDepth - 1))
        let alpha = max(theme.quoteLevelMinOpacity, step)
        m.addAttribute(.foregroundColor,
                       value: theme.secondaryTextColor.withAlphaComponent(alpha), range: full)
        m.addAttribute(.paragraphStyle, value: bodyParagraphStyle(headIndent: theme.blockquoteIndent), range: full)
        // Tag the range so `HuggingLayoutManager` paints a soft rounded fill behind
        // it (the drawing can't be expressed as text attributes). The bar is off by
        // default — the fill alone reads as a quote. A theme with no fill (ChatGPT's)
        // turns the bar on instead.
        m.addAttribute(.blockquoteFill, value: theme.blockquoteBackground, range: full)
        if theme.blockquoteBarWidth > 0 {
            m.addAttribute(.blockquoteBar, value: theme.blockquoteBar, range: full)
            m.addAttribute(.blockquoteBarWidth, value: theme.blockquoteBarWidth as NSNumber, range: full)
        }
        return m
    }
}
