import Foundation
import PDFKit

/// Searches a document for a text query, returning matching pages with context.
public struct SearchDocumentTool: AgentTool, Sendable {
    public let name = "search_document"
    public let description = """
        Search the current document for a text query. Returns matching pages with \
        surrounding context. Useful for finding specific content without reading the \
        entire document.
        """
    public let filePath: String
    public let documentType: String
    public let pageCount: Int

    public init(filePath: String, documentType: String, pageCount: Int) {
        self.filePath = filePath
        self.documentType = documentType
        self.pageCount = pageCount
    }

    public var inputSchema: [String: Any] {
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

    public func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
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
