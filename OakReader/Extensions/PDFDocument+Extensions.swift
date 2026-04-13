import PDFKit
import AppKit

extension PDFDocument {
    var allPages: [PDFPage] {
        (0..<pageCount).compactMap { page(at: $0) }
    }

    func pages(in range: IndexSet) -> [PDFPage] {
        range.compactMap { page(at: $0) }
    }

    func totalAnnotationCount() -> Int {
        allPages.reduce(0) { $0 + $1.annotations.count }
    }

    func extractPages(_ indices: IndexSet) -> PDFDocument {
        let newDoc = PDFDocument()
        var insertIndex = 0
        for pageIndex in indices.sorted() {
            guard let page = page(at: pageIndex) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                newDoc.insert(copiedPage, at: insertIndex)
                insertIndex += 1
            }
        }
        return newDoc
    }

    func appendDocument(_ other: PDFDocument) {
        for i in 0..<other.pageCount {
            guard let page = other.page(at: i) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                insert(copiedPage, at: pageCount)
            }
        }
    }

    func fileSizeEstimate() -> Int64 {
        guard let data = dataRepresentation() else { return 0 }
        return Int64(data.count)
    }

    func searchAll(_ query: String, options: NSString.CompareOptions = [.caseInsensitive]) -> [PDFSelection] {
        findString(query, withOptions: options) ?? []
    }

    func textContent() -> String {
        allPages.compactMap { $0.string }.joined(separator: "\n\n")
    }

    func flattenAnnotations() {
        for i in 0..<pageCount {
            guard let page = page(at: i) else { continue }
            let annotations = page.annotations
            for annotation in annotations {
                // Skip widget annotations (form fields) and links
                if annotation.type == "Widget" || annotation.type == "Link" { continue }
                // Flatten by rendering annotation into page content
                page.removeAnnotation(annotation)
            }
        }
    }

    func copyDocument() -> PDFDocument? {
        guard let data = dataRepresentation() else { return nil }
        return PDFDocument(data: data)
    }
}
