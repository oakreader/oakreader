import Foundation
import PDFKit

struct TextExtractionService {

    func extractText(from page: PDFPage) -> String {
        page.string ?? ""
    }
}
