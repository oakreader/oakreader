import Foundation
import PDFKit
import AppKit

struct TextExtractionService {

    func extractText(from page: PDFPage) -> String {
        page.string ?? ""
    }

    func extractAttributedText(from page: PDFPage) -> NSAttributedString? {
        page.attributedString
    }

    func extractAllText(from document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { index in
            document.page(at: index)?.string
        }.joined(separator: "\n\n")
    }

    func extractAllAttributedText(from document: PDFDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let separator = NSAttributedString(string: "\n\n")

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            if let attrText = page.attributedString {
                if result.length > 0 {
                    result.append(separator)
                }
                result.append(attrText)
            }
        }

        return result
    }

    func extractTextByPage(from document: PDFDocument) -> [(pageIndex: Int, text: String)] {
        (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return (pageIndex: index, text: page.string ?? "")
        }
    }
}
