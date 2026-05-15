import Foundation
import PDFKit
import OakAgent

// MARK: - HTML Text Extraction

/// Thread-safe HTML text extraction using XMLDocument.
/// Single source of truth — used by document tools and context snapshot builder.
enum HTMLTextExtractor {
    private static let suppressedTags: Set<String> = [
        "script", "style", "noscript", "svg", "math"
    ]

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "nav", "main",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre",
        "ul", "ol", "li", "table", "tr", "td", "th",
        "br", "hr", "figcaption", "figure", "details", "summary"
    ]

    /// Extract plain text from HTML data using XMLDocument (thread-safe).
    static func extractText(from data: Data) -> String {
        guard let doc = try? XMLDocument(data: data, options: .documentTidyHTML) else {
            return String(data: data, encoding: .utf8) ?? ""
        }

        var parts: [String] = []
        if let root = doc.rootElement() {
            collectText(from: root, into: &parts)
        }

        return parts.joined()
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
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

            if suppressedTags.contains(tag) { return }

            let isBlock = blockTags.contains(tag)
            if isBlock { parts.append("\n") }

            for child in node.children ?? [] {
                collectText(from: child, into: &parts)
            }

            if isBlock { parts.append("\n") }

        default:
            for child in node.children ?? [] {
                collectText(from: child, into: &parts)
            }
        }
    }
}

// MARK: - Page Range Parsing

/// Parse page range strings like "1-5", "3,7,12" into 0-based indices.
enum PageRangeParser {
    static func parse(_ input: String, maxPage: Int) -> [Int] {
        var indices: [Int] = []
        let parts = input.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for part in parts {
            if part.contains("-") {
                let bounds = part.split(separator: "-").compactMap {
                    Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard bounds.count == 2, bounds[0] >= 1, bounds[1] >= bounds[0] else { continue }
                let start = max(bounds[0], 1)
                let end = min(bounds[1], maxPage)
                for page in start...end {
                    indices.append(page - 1)
                }
            } else if let page = Int(part), page >= 1, page <= maxPage {
                indices.append(page - 1)
            }
        }
        return indices
    }
}

// MARK: - Read Document Tool

/// Reads text content from a document. For PDFs, supports page range selection.
/// Opens the file fresh on each invocation — no non-Sendable captures.
struct ReadDocumentTool: AgentTool, Sendable {
    let name = "read_document"
    let description = """
        Read text from the current document. For PDFs, specify page numbers (1-based). \
        Returns extracted text content. Examples: "1-5" for pages 1 through 5, \
        "3,7,12" for specific pages, or omit for the current page.
        """
    let filePath: String
    let documentType: ContentType
    let pageCount: Int

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "pages": [
                    "type": "string",
                    "description": "Page range (1-based). Examples: \"1-5\", \"3,7,12\". Omit for all pages. PDFs only."
                ]
            ]
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        let url = URL(fileURLWithPath: filePath)

        switch documentType {
        case .pdf:
            return readPDF(url: url, pagesParam: input["pages"])
        case .markdown, .video:
            return readTextFile(url: url)
        case .html:
            return readHTML(url: url)
        case .audio:
            return .error("Audio documents do not support text reading.")
        }
    }

    private func readPDF(url: URL, pagesParam: String?) -> ToolOutput {
        guard let pdf = PDFDocument(url: url) else {
            return .error("Failed to open PDF at \(filePath)")
        }

        let pageIndices: [Int]
        if let param = pagesParam, !param.isEmpty {
            pageIndices = PageRangeParser.parse(param, maxPage: pdf.pageCount)
            if pageIndices.isEmpty {
                // swiftlint:disable:next line_length
                return .error("Invalid page range: \"\(param)\". Use formats like \"1-5\" or \"3,7,12\". Document has \(pdf.pageCount) pages.")
            }
        } else {
            pageIndices = Array(0..<pdf.pageCount)
        }

        var parts: [String] = []
        for index in pageIndices {
            guard let page = pdf.page(at: index) else { continue }
            let text = page.string ?? ""
            if !text.isEmpty {
                parts.append("--- Page \(index + 1) ---\n\(text)")
            }
        }

        let result = parts.joined(separator: "\n\n")
        if result.isEmpty {
            return .success("No text content found on the requested pages.")
        }
        return .success(String(result.prefix(50_000)))
    }

    private func readTextFile(url: URL) -> ToolOutput {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Failed to read file at \(filePath)")
        }
        return .success(String(content.prefix(50_000)))
    }

    private func readHTML(url: URL) -> ToolOutput {
        // Prefer the markdown version saved by the browser extension (content.md alongside HTML)
        let mdURL = url.deletingLastPathComponent().appendingPathComponent("content.md")
        if let markdown = try? String(contentsOf: mdURL, encoding: .utf8), !markdown.isEmpty {
            return .success(String(markdown.prefix(50_000)))
        }

        // Fall back to proper HTML parsing via XMLDocument
        guard let data = try? Data(contentsOf: url) else {
            return .error("Failed to read web page at \(filePath)")
        }
        let text = HTMLTextExtractor.extractText(from: data)
        if text.isEmpty {
            return .error("Failed to extract text from web page")
        }
        return .success(String(text.prefix(50_000)))
    }
}

// MARK: - Search Document Tool

/// Searches a document for a text query, returning matching pages with context.
struct SearchDocumentTool: AgentTool, Sendable {
    let name = "search_document"
    let description = """
        Search the current document for a text query. Returns matching pages with \
        surrounding context. Useful for finding specific content without reading the \
        entire document.
        """
    let filePath: String
    let documentType: ContentType
    let pageCount: Int

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "The text to search for (case-insensitive)"
                ],
                "max_results": [
                    "type": "string",
                    "description": "Maximum number of matches to return (default: 10)"
                ]
            ],
            "required": ["query"]
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let query = input["query"], !query.isEmpty else {
            return .error("Missing required parameter: query")
        }

        let maxResults = Int(input["max_results"] ?? "10") ?? 10
        let url = URL(fileURLWithPath: filePath)

        switch documentType {
        case .pdf:
            return searchPDF(url: url, query: query, maxResults: maxResults)
        case .markdown, .video:
            return searchTextFile(url: url, query: query, maxResults: maxResults)
        case .html:
            return searchHTML(url: url, query: query, maxResults: maxResults)
        case .audio:
            return .error("Audio documents do not support text search.")
        }
    }

    private func searchPDF(url: URL, query: String, maxResults: Int) -> ToolOutput {
        guard let pdf = PDFDocument(url: url) else {
            return .error("Failed to open PDF at \(filePath)")
        }

        let queryLower = query.lowercased()
        var results: [String] = []

        for pageIndex in 0..<pdf.pageCount {
            guard results.count < maxResults else { break }
            guard let page = pdf.page(at: pageIndex) else { continue }
            guard let pageText = page.string, !pageText.isEmpty else { continue }

            let textLower = pageText.lowercased()
            if textLower.contains(queryLower) {
                let snippets = SnippetExtractor.extractSnippets(
                    from: pageText, query: query, maxSnippets: 2
                )
                let snippetText = snippets.joined(separator: "\n  ...\n")
                results.append("Page \(pageIndex + 1):\n  \(snippetText)")
            }
        }

        if results.isEmpty {
            return .success("No matches found for \"\(query)\" in the document.")
        }
        let joined = results.joined(separator: "\n\n")
        return .success("Found \(results.count) page(s) matching \"\(query)\":\n\n\(joined)")
    }

    private func searchTextFile(url: URL, query: String, maxResults: Int) -> ToolOutput {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Failed to read file at \(filePath)")
        }
        return searchPlainText(content, query: query, maxResults: maxResults)
    }

    private func searchHTML(url: URL, query: String, maxResults: Int) -> ToolOutput {
        // Prefer markdown version if available
        let mdURL = url.deletingLastPathComponent().appendingPathComponent("content.md")
        if let markdown = try? String(contentsOf: mdURL, encoding: .utf8), !markdown.isEmpty {
            return searchPlainText(markdown, query: query, maxResults: maxResults)
        }

        guard let data = try? Data(contentsOf: url) else {
            return .error("Failed to read web page at \(filePath)")
        }
        let text = HTMLTextExtractor.extractText(from: data)
        return searchPlainText(text, query: query, maxResults: maxResults)
    }

    private func searchPlainText(_ text: String, query: String, maxResults: Int) -> ToolOutput {
        let lines = text.components(separatedBy: .newlines)
        let queryLower = query.lowercased()
        var results: [String] = []

        for (lineNum, line) in lines.enumerated() {
            guard results.count < maxResults else { break }
            if line.lowercased().contains(queryLower) {
                let start = max(0, lineNum - 1)
                let end = min(lines.count - 1, lineNum + 1)
                let ctx = lines[start...end].joined(separator: "\n")
                results.append("Line \(lineNum + 1):\n  \(ctx)")
            }
        }

        if results.isEmpty {
            return .success("No matches found for \"\(query)\".")
        }
        let joined = results.joined(separator: "\n\n")
        return .success("Found \(results.count) match(es) for \"\(query)\":\n\n\(joined)")
    }
}

// MARK: - Snippet Extractor

/// Extracts short text snippets around query matches.
enum SnippetExtractor {
    static func extractSnippets(from text: String, query: String, maxSnippets: Int) -> [String] {
        let textLower = text.lowercased()
        let queryLower = query.lowercased()
        var snippets: [String] = []
        var searchStart = textLower.startIndex

        while snippets.count < maxSnippets,
              let range = textLower.range(of: queryLower, range: searchStart..<textLower.endIndex) {
            let snippetStart = text.index(
                range.lowerBound, offsetBy: -100, limitedBy: text.startIndex
            ) ?? text.startIndex
            let snippetEnd = text.index(
                range.upperBound, offsetBy: 100, limitedBy: text.endIndex
            ) ?? text.endIndex
            let snippet = String(text[snippetStart..<snippetEnd])
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let prefix = snippetStart == text.startIndex ? "" : "..."
            let suffix = snippetEnd == text.endIndex ? "" : "..."
            snippets.append("\(prefix)\(snippet)\(suffix)")

            searchStart = range.upperBound
        }

        return snippets
    }
}
