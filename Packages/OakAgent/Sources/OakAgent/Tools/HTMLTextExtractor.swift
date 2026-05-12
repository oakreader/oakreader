import Foundation

/// Extracts plain text from HTML using macOS Foundation's XMLDocument parser.
/// Thread-safe (no main-thread requirement unlike NSAttributedString(html:)).
public enum HTMLTextExtractor {
    /// Tags whose content should be suppressed entirely.
    private static let suppressedTags: Set<String> = [
        "script", "style", "noscript", "svg", "math"
    ]

    /// Block-level tags that should produce a newline boundary.
    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "nav", "main",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre",
        "ul", "ol", "li", "table", "tr", "td", "th",
        "br", "hr", "figcaption", "figure", "details", "summary"
    ]

    public static func extractText(from data: Data) -> String {
        // XMLDocument with .documentTidyHTML cleans up malformed HTML
        guard let doc = try? XMLDocument(data: data, options: .documentTidyHTML) else {
            // Last resort: decode as string and return raw
            return String(data: data, encoding: .utf8) ?? ""
        }

        var parts: [String] = []
        if let root = doc.rootElement() {
            collectText(from: root, into: &parts)
        }

        // Join, collapse excessive newlines
        return parts.joined()
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(
                of: "\n{3,}",
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collectText(from node: XMLNode, into parts: inout [String]) {
        switch node.kind {
        case .text:
            if let text = node.stringValue, !text.isEmpty {
                parts.append(text)
            }

        case .element:
            guard let element = node as? XMLElement else { return }
            let tag = element.name?.lowercased() ?? ""

            // Skip suppressed tags entirely
            if suppressedTags.contains(tag) { return }

            // Block elements get a newline before
            let isBlock = blockTags.contains(tag)
            if isBlock { parts.append("\n") }

            // Recurse into children
            for child in node.children ?? [] {
                collectText(from: child, into: &parts)
            }

            // Block elements get a newline after
            if isBlock { parts.append("\n") }

        default:
            // Recurse for document nodes, etc.
            for child in node.children ?? [] {
                collectText(from: child, into: &parts)
            }
        }
    }
}
