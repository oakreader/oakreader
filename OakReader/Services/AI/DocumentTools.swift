import Foundation
import PDFKit
import OakAgent

// MARK: - Read Document Tool

/// Reads text content from the current document. For PDFs, supports page range selection.
/// Opens the file fresh on each invocation — no non-Sendable captures.
struct ReadDocumentTool: AgentTool, Sendable {
    let name = "read_document"
    let description = """
        Read text from the current document. For PDFs, specify page numbers (1-based). \
        Returns extracted text content. Examples: "1-5" for pages 1 through 5, \
        "3,7,12" for specific pages, or omit for the current page.
        """
    let filePath: String
    let documentType: String
    let pageCount: Int

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "pages": [
                    "type": "string",
                    // swiftlint:disable:next line_length
                    "description": "Page range (1-based). Examples: \"1-5\", \"3,7,12\". Omit for all pages. PDFs only."
                ]
            ]
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        let url = URL(fileURLWithPath: filePath)

        switch documentType {
        case "pdf":
            return readPDF(url: url, pagesParam: input["pages"])
        case "markdown":
            return readTextFile(url: url)
        case "webSnapshot":
            return readWebSnapshot(url: url)
        case "embed":
            return readTextFile(url: url)
        default:
            return .error("Unsupported document type: \(documentType)")
        }
    }

    private func readPDF(url: URL, pagesParam: String?) -> ToolOutput {
        guard let pdf = PDFDocument(url: url) else {
            return .error("Failed to open PDF at \(filePath)")
        }

        let pageIndices: [Int]
        if let param = pagesParam, !param.isEmpty {
            pageIndices = parsePageRange(param, maxPage: pdf.pageCount)
            if pageIndices.isEmpty {
                return .error("Invalid page range: \"\(param)\". Use formats like \"1-5\" or \"3,7,12\". Document has \(pdf.pageCount) pages.")
            }
        } else {
            // All pages
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
        // Truncate to 50K chars
        return .success(String(result.prefix(50_000)))
    }

    private func readTextFile(url: URL) -> ToolOutput {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Failed to read file at \(filePath)")
        }
        return .success(String(content.prefix(50_000)))
    }

    private func readWebSnapshot(url: URL) -> ToolOutput {
        // Prefer the markdown version saved by the browser extension (content.md alongside HTML)
        let mdURL = url.deletingLastPathComponent().appendingPathComponent("content.md")
        if let markdown = try? String(contentsOf: mdURL, encoding: .utf8), !markdown.isEmpty {
            return .success(String(markdown.prefix(50_000)))
        }

        // Fall back to proper HTML parsing via XMLDocument
        guard let data = try? Data(contentsOf: url) else {
            return .error("Failed to read web snapshot at \(filePath)")
        }
        let text = HTMLTextExtractor.extractText(from: data)
        if text.isEmpty {
            return .error("Failed to extract text from web snapshot")
        }
        return .success(String(text.prefix(50_000)))
    }

    /// Parse a page range string like "1-5", "3,7,12", "1-3,8,10-12" into 0-based indices.
    private func parsePageRange(_ input: String, maxPage: Int) -> [Int] {
        var indices: [Int] = []
        let parts = input.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        for part in parts {
            if part.contains("-") {
                let bounds = part.split(separator: "-").compactMap { Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard bounds.count == 2, bounds[0] >= 1, bounds[1] >= bounds[0] else { continue }
                let start = max(bounds[0], 1)
                let end = min(bounds[1], maxPage)
                for page in start...end {
                    indices.append(page - 1) // Convert to 0-based
                }
            } else if let page = Int(part), page >= 1, page <= maxPage {
                indices.append(page - 1)
            }
        }
        return indices
    }
}

// MARK: - Search Document Tool

/// Searches the current document for a text query, returning matching pages with context.
struct SearchDocumentTool: AgentTool, Sendable {
    let name = "search_document"
    let description = """
        Search the current document for a text query. Returns matching pages with \
        surrounding context. Useful for finding specific content without reading the \
        entire document.
        """
    let filePath: String
    let documentType: String
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
        case "pdf":
            return searchPDF(url: url, query: query, maxResults: maxResults)
        case "markdown", "embed":
            return searchTextFile(url: url, query: query, maxResults: maxResults)
        case "webSnapshot":
            return searchWebSnapshot(url: url, query: query, maxResults: maxResults)
        default:
            return .error("Unsupported document type: \(documentType)")
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
                // Extract snippets around each match
                let snippets = extractSnippets(from: pageText, query: query, maxSnippets: 2)
                let snippetText = snippets.joined(separator: "\n  ...\n")
                results.append("Page \(pageIndex + 1):\n  \(snippetText)")
            }
        }

        if results.isEmpty {
            return .success("No matches found for \"\(query)\" in the document.")
        }
        return .success("Found \(results.count) page(s) matching \"\(query)\":\n\n\(results.joined(separator: "\n\n"))")
    }

    private func searchTextFile(url: URL, query: String, maxResults: Int) -> ToolOutput {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Failed to read file at \(filePath)")
        }
        return searchPlainText(content, query: query, maxResults: maxResults)
    }

    private func searchWebSnapshot(url: URL, query: String, maxResults: Int) -> ToolOutput {
        // Prefer markdown version if available
        let mdURL = url.deletingLastPathComponent().appendingPathComponent("content.md")
        if let markdown = try? String(contentsOf: mdURL, encoding: .utf8), !markdown.isEmpty {
            return searchPlainText(markdown, query: query, maxResults: maxResults)
        }

        guard let data = try? Data(contentsOf: url) else {
            return .error("Failed to read web snapshot at \(filePath)")
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
                // Show a few lines of context
                let start = max(0, lineNum - 1)
                let end = min(lines.count - 1, lineNum + 1)
                let context = lines[start...end].joined(separator: "\n")
                results.append("Line \(lineNum + 1):\n  \(context)")
            }
        }

        if results.isEmpty {
            return .success("No matches found for \"\(query)\".")
        }
        return .success("Found \(results.count) match(es) for \"\(query)\":\n\n\(results.joined(separator: "\n\n"))")
    }

    /// Extract short text snippets around matches in a page.
    private func extractSnippets(from text: String, query: String, maxSnippets: Int) -> [String] {
        let textLower = text.lowercased()
        let queryLower = query.lowercased()
        var snippets: [String] = []
        var searchStart = textLower.startIndex

        while snippets.count < maxSnippets,
              let range = textLower.range(of: queryLower, range: searchStart..<textLower.endIndex) {
            // Expand to ~100 chars on each side
            let snippetStart = text.index(range.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
            let snippetEnd = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
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

// MARK: - Read Notes Tool

/// Reads notes associated with the current document.
struct ReadNotesTool: AgentTool, Sendable {
    let name = "read_notes"
    let description = """
        Read notes for the current document. Call without arguments to list all notes, \
        or specify a note title to read its full content.
        """
    let notes: [(id: String, title: String)]

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Title of the note to read. Omit to list all notes."
                ]
            ]
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard !notes.isEmpty else {
            return .success("No notes found for this document.")
        }

        if let title = input["title"], !title.isEmpty {
            return readNote(title: title)
        } else {
            return listNotes()
        }
    }

    private func listNotes() -> ToolOutput {
        let list = notes.enumerated().map { (i, note) in
            "\(i + 1). \(note.title.isEmpty ? "(Untitled)" : note.title)"
        }.joined(separator: "\n")
        return .success("Notes for this document:\n\(list)")
    }

    private func readNote(title: String) -> ToolOutput {
        let titleLower = title.lowercased()
        guard let match = notes.first(where: { $0.title.lowercased() == titleLower })
                ?? notes.first(where: { $0.title.lowercased().contains(titleLower) }) else {
            let available = notes.map { $0.title.isEmpty ? "(Untitled)" : $0.title }.joined(separator: ", ")
            return .error("Note \"\(title)\" not found. Available notes: \(available)")
        }

        guard let noteId = UUID(uuidString: match.id) else {
            return .error("Invalid note ID")
        }

        let url = CatalogDatabase.noteFileURL(noteId: noteId)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Failed to read note content from disk")
        }

        if content.isEmpty {
            return .success("Note \"\(match.title)\" is empty.")
        }
        return .success("Note: \(match.title)\n\n\(String(content.prefix(30_000)))")
    }
}

// MARK: - HTML Text Extraction

/// Extracts plain text from HTML using macOS Foundation's XMLDocument parser.
/// Thread-safe (no main-thread requirement unlike NSAttributedString(html:)).
enum HTMLTextExtractor {
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

    static func extractText(from data: Data) -> String {
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
