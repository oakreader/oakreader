import AppKit
import PDFKit

struct ClipboardCoordinator {
    static let pdfPagePasteboardType = NSPasteboard.PasteboardType("com.oakreader.page")

    static func copyPages(_ pages: [PDFPage], from document: PDFDocument) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let newDoc = PDFDocument()
        for (index, page) in pages.enumerated() {
            if let copy = page.copy() as? PDFPage {
                newDoc.insert(copy, at: index)
            }
        }

        if let data = newDoc.dataRepresentation() {
            pasteboard.setData(data, forType: .pdf)
        }
    }

    static func pastePages(into document: PDFDocument, at index: Int) -> Int {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .pdf),
              let sourceDoc = PDFDocument(data: data) else { return 0 }

        var inserted = 0
        for i in 0..<sourceDoc.pageCount {
            guard let page = sourceDoc.page(at: i),
                  let copy = page.copy() as? PDFPage else { continue }
            document.insert(copy, at: index + inserted)
            inserted += 1
        }
        return inserted
    }

    static func canPastePages() -> Bool {
        NSPasteboard.general.data(forType: .pdf) != nil
    }

    static func copyAnnotation(_ annotation: PDFAnnotation) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Store annotation properties as a dictionary
        let data: [String: Any] = [
            "type": annotation.type ?? "",
            "bounds": NSStringFromRect(annotation.bounds),
            "contents": annotation.contents ?? "",
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
            pasteboard.setData(jsonData, forType: .string)
        }
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
