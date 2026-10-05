import Foundation
import PDFKit

/// Extracts DOIs and arXiv IDs from PDF text content.
///
/// The entry points are `async` on purpose. Opening a `PDFDocument` is not
/// cheap — measured at 1016 ms for a 21 MB, 541-page book — and the callers are
/// SwiftUI `.onAppear` handlers, where a bare `Task { }` inherits `@MainActor`
/// and would run that work on the main thread. Making the call `async` and
/// hopping to a detached task takes the choice away from the call site.
struct DOIExtractorService {

    /// Extract a DOI from the first few pages of a PDF.
    static func extractDOI(from pdfURL: URL) async -> String? {
        await scan(pdfURL) { findDOI(in: $0) }
    }

    /// Extract an arXiv ID from the first few pages of a PDF.
    static func extractArXivID(from pdfURL: URL) async -> String? {
        await scan(pdfURL) { findArXivID(in: $0) }
    }

    // MARK: - Private

    /// How far in a paper's own identifier is still on the page.
    private static let pagesToScan = 3

    /// Read the leading pages off the main thread, stopping at the first hit.
    private static func scan(
        _ pdfURL: URL,
        _ find: @escaping @Sendable (String) -> String?
    ) async -> String? {
        await Task.detached(priority: .utility) {
            guard let pdfDoc = PDFDocument(url: pdfURL) else { return nil }
            for i in 0..<min(pdfDoc.pageCount, pagesToScan) {
                guard let text = pdfDoc.page(at: i)?.string else { continue }
                if let found = find(text) { return found }
            }
            return nil
        }.value
    }

    // swiftlint:disable force_try
    private static let doiPattern = try! NSRegularExpression(
        pattern: #"10\.\d{4,9}/[^\s]+"#,
        options: [.caseInsensitive]
    )

    private static let arxivPattern = try! NSRegularExpression(
        pattern: #"arXiv:\d{4}\.\d{4,5}(v\d+)?"#,
        options: [.caseInsensitive]
    )
    // swiftlint:enable force_try

    static func findDOI(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = doiPattern.firstMatch(in: text, range: range) else { return nil }
        guard let matchRange = Range(match.range, in: text) else { return nil }
        var doi = String(text[matchRange])
        // Clean trailing punctuation that isn't part of the DOI
        while let last = doi.last, [".", ",", ";", ")", "]", ">", "\"", "'"].contains(String(last)) {
            doi.removeLast()
        }
        return doi
    }

    static func findArXivID(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = arxivPattern.firstMatch(in: text, range: range) else { return nil }
        guard let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }
}
