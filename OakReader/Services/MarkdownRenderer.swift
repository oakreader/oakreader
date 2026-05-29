import Foundation
import CMarkGFM

/// Thin wrapper around cmark-gfm for converting markdown to styled HTML.
enum MarkdownRenderer {

    // MARK: - Public API

    /// Convert markdown text to GFM HTML fragment.
    static func renderHTML(_ markdown: String, notesBaseURL: URL? = nil) -> String {
        var preprocessed = preprocessReferences(markdown)
        if let base = notesBaseURL {
            preprocessed = resolveImagePaths(preprocessed, baseURL: base)
        }
        let html = cmarkToHTML(preprocessed)
        return postprocessTags(html)
    }

    /// Assemble a full HTML page from the template + rendered markdown content.
    static func pageHTML(
        content: String, isDark: Bool, fontSize: Int, fontFamily: String,
        codeFontFamily: String = "SF Mono",
        fontFaceCSS: String = "", accentColor: String = "#0CA69A", notesBaseURL: URL? = nil
    ) -> String {
        guard let templateURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "Preview.bundle"
        ),
            let template = try? String(contentsOf: templateURL, encoding: .utf8)
        else {
            // Fallback: raw HTML without styling
            return "<html><body>\(content)</body></html>"
        }

        let renderedHTML = renderHTML(content, notesBaseURL: notesBaseURL)

        // Build dynamic CSS for font overrides + accent color
        // swiftlint:disable:next line_length
        let fontStack = "\(cssFontFamilyToken(fontFamily)), -apple-system, BlinkMacSystemFont, \"Helvetica Neue\", \"PingFang SC\", \"Hiragino Sans GB\", \"Microsoft YaHei\", Arial, sans-serif"
        let codeStack = "\(cssFontFamilyToken(codeFontFamily)), ui-monospace, Menlo, Consolas, \"Courier New\", monospace"
        let dynamicCSS = """
        \(fontFaceCSS)
        html { font-size: \(fontSize)px; }
        :root { --text-font: \(fontStack); --code-text-font: \(codeStack); --accent-color: \(accentColor); }
        .oak-tag { color: \(accentColor); }
        .heti code, .heti pre code { font-family: \(codeStack); font-size: 0.9em; }
        """

        let themeClass = isDark ? "darkmode" : "lightmode"

        var html = template
        html = html.replacingOccurrences(of: "DOWN_HTML", with: renderedHTML)
        html = html.replacingOccurrences(of: "DOWN_CSS", with: dynamicCSS)
        html = html.replacingOccurrences(of: "CUSTOM_CSS", with: themeClass)

        return html
    }

    private static func cssFontFamilyToken(_ family: String) -> String {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "serif" }
        if trimmed.contains(",") || trimmed.hasPrefix("-") {
            return trimmed
        }
        return "\"\(trimmed.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// Convert `[[references]]` to `<a href="oak-ref://...">` links before cmark processing.
    static func preprocessReferences(_ markdown: String) -> String {
        // Pattern: [[any text]] → [any text](oak-ref://encoded)
        guard let regex = try? NSRegularExpression(pattern: #"\[\[(.+?)\]\]"#) else {
            return markdown
        }

        let nsString = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: nsString.length))

        var result = markdown
        // Process in reverse to preserve indices
        for match in matches.reversed() {
            let innerRange = match.range(at: 1)
            let innerText = nsString.substring(with: innerRange)
            let encoded = innerText.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? innerText
            let replacement = "[\(innerText)](oak-ref://\(encoded))"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }

        return result
    }

    /// Resolve relative image paths to absolute file:// URLs so WKWebView can load them.
    static func resolveImagePaths(_ markdown: String, baseURL: URL) -> String {
        // Match ![alt](relativePath) but skip http(s):// and file:// URLs
        let pattern = #"!\[([^\]]*)\]\((?!https?://|file://)([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }

        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))

        var result = markdown
        for match in matches.reversed() {
            let altRange = match.range(at: 1)
            let pathRange = match.range(at: 2)
            let alt = ns.substring(with: altRange)
            let relativePath = ns.substring(with: pathRange)
            let absoluteURL = baseURL.appendingPathComponent(relativePath)
            let replacement = "![\(alt)](\(absoluteURL.absoluteString))"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    /// Wrap #tags in the rendered HTML with <span class="oak-tag"> for styling.
    static func postprocessTags(_ html: String) -> String {
        // Match #tag patterns that aren't inside HTML tags or code elements
        let pattern = #"(?<=\s|>|^)(#[a-zA-Z\u{4e00}-\u{9fff}][a-zA-Z0-9\u{4e00}-\u{9fff}_/-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return html }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var result = html
        for match in matches.reversed() {
            let tagRange = match.range(at: 1)
            // Skip if inside an HTML tag (between < and >)
            let before = ns.substring(to: tagRange.location)
            if before.lastIndex(of: "<").map({ before[$0...].contains(">") }) == false { continue }
            let tag = ns.substring(with: tagRange)
            result = (result as NSString).replacingCharacters(
                in: tagRange, with: "<span class=\"oak-tag\">\(tag)</span>"
            )
        }
        return result
    }

    // MARK: - Private

    /// Use cmark-gfm C API to convert markdown to HTML with GFM extensions.
    private static func cmarkToHTML(_ markdown: String) -> String {
        // Ensure GFM extensions are registered
        cmark_gfm_core_extensions_ensure_registered()

        let options: Int32 = CMARK_OPT_UNSAFE | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES

        // Create parser
        guard let parser = cmark_parser_new(options) else {
            return escapeHTML(markdown)
        }
        defer { cmark_parser_free(parser) }

        // Attach GFM extensions
        let extensionNames = ["table", "strikethrough", "tasklist", "autolink"]
        for name in extensionNames {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        // Parse markdown
        let data = Array(markdown.utf8)
        cmark_parser_feed(parser, data, data.count)

        guard let document = cmark_parser_finish(parser) else {
            return escapeHTML(markdown)
        }
        defer { cmark_node_free(document) }

        // Get the attached extensions list from the parser for rendering
        let extensions = cmark_parser_get_syntax_extensions(parser)

        // Render to HTML
        guard let cString = cmark_render_html(document, options, extensions) else {
            return escapeHTML(markdown)
        }

        let html = String(cString: cString)
        free(cString)

        return cleanMathBlocks(html)
    }

    /// Remove spurious <br> tags inside $$ math blocks that cmark inserts due to HARDBREAKS.
    private static func cleanMathBlocks(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\$\$(.*?)\$\$"#,
            options: .dotMatchesLineSeparators
        ) else {
            return html
        }

        let nsString = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsString.length))

        var result = html
        for match in matches.reversed() {
            let fullRange = match.range
            let original = nsString.substring(with: fullRange)
            let cleaned = original.replacingOccurrences(of: "<br />", with: "\n")
                .replacingOccurrences(of: "<br>", with: "\n")
            result = (result as NSString).replacingCharacters(in: fullRange, with: cleaned)
        }

        return result
    }

    /// Basic HTML escape for fallback rendering.
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
