import Foundation
import PDFKit
import AppKit

struct DocumentConversionService {

    private let textExtraction = TextExtractionService()

    // MARK: - Export to RTF

    func exportToRTF(_ document: PDFDocument) throws -> Data {
        let attributedText = NSMutableAttributedString()
        let pageBreak = NSAttributedString(string: "\n\n")

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }

            if attributedText.length > 0 {
                attributedText.append(pageBreak)
            }

            if let attrString = page.attributedString {
                attributedText.append(attrString)
            } else if let plainText = page.string, !plainText.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont(name: PDFDefaults.defaultFontName, size: PDFDefaults.defaultFontSize)
                        ?? NSFont.systemFont(ofSize: PDFDefaults.defaultFontSize)
                ]
                attributedText.append(NSAttributedString(string: plainText, attributes: attrs))
            }
        }

        guard attributedText.length > 0 else {
            throw OakReaderError.exportFailed("Document contains no extractable text.")
        }

        let fullRange = NSRange(location: 0, length: attributedText.length)
        guard let rtfData = try? attributedText.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            throw OakReaderError.exportFailed("Failed to generate RTF data.")
        }

        return rtfData
    }

    // MARK: - Export to Plain Text

    func exportToPlainText(_ document: PDFDocument) -> String {
        textExtraction.extractAllText(from: document)
    }

    // MARK: - Export to HTML

    func exportToHTML(_ document: PDFDocument) throws -> Data {
        let attributedText = NSMutableAttributedString()
        let pageBreak = NSAttributedString(string: "\n\n")

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }

            if attributedText.length > 0 {
                attributedText.append(pageBreak)
            }

            if let attrString = page.attributedString {
                attributedText.append(attrString)
            } else if let plainText = page.string, !plainText.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont(name: PDFDefaults.defaultFontName, size: PDFDefaults.defaultFontSize)
                        ?? NSFont.systemFont(ofSize: PDFDefaults.defaultFontSize)
                ]
                attributedText.append(NSAttributedString(string: plainText, attributes: attrs))
            }
        }

        guard attributedText.length > 0 else {
            throw OakReaderError.exportFailed("Document contains no extractable text.")
        }

        let fullRange = NSRange(location: 0, length: attributedText.length)
        guard let htmlData = try? attributedText.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) else {
            throw OakReaderError.exportFailed("Failed to generate HTML data.")
        }

        return htmlData
    }
}
