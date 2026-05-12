import Foundation
import PDFKit

/// Reads text content from a document. For PDFs, supports page range selection.
/// Opens the file fresh on each invocation — no non-Sendable captures.
public struct ReadDocumentTool: AgentTool, Sendable {
    public let name = "read_document"
    public let description = """
        Read text from the current document. For PDFs, specify page numbers (1-based). \
        Returns extracted text content. Examples: "1-5" for pages 1 through 5, \
        "3,7,12" for specific pages, or omit for the current page.
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
                "pages": [
                    "type": "string",
                    "description": "Page range (1-based). Examples: \"1-5\", \"3,7,12\". Omit for all pages. PDFs only."
                ]
            ]
        ]
    }

    public func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
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
}
