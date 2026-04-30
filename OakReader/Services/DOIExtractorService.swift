import Foundation
import PDFKit

/// Extracts DOIs and arXiv IDs from PDF text content.
struct DOIExtractorService {

    /// Extract a DOI from the first few pages of a PDF.
    static func extractDOI(from pdfURL: URL) -> String? {
        guard let pdfDoc = PDFDocument(url: pdfURL) else { return nil }

        let pagesToScan = min(pdfDoc.pageCount, 3)
        for i in 0..<pagesToScan {
            guard let page = pdfDoc.page(at: i),
                  let text = page.string else { continue }
            if let doi = findDOI(in: text) {
                return doi
            }
        }
        return nil
    }

    /// Extract an arXiv ID from the first few pages of a PDF.
    static func extractArXivID(from pdfURL: URL) -> String? {
        guard let pdfDoc = PDFDocument(url: pdfURL) else { return nil }

        let pagesToScan = min(pdfDoc.pageCount, 3)
        for i in 0..<pagesToScan {
            guard let page = pdfDoc.page(at: i),
                  let text = page.string else { continue }
            if let arxivId = findArXivID(in: text) {
                return arxivId
            }
        }
        return nil
    }

    // MARK: - Private

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

    private static func findArXivID(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = arxivPattern.firstMatch(in: text, range: range) else { return nil }
        guard let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }
}
