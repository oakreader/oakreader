import Foundation
import PDFKit

struct BookmarkModel: Identifiable {
    let id: UUID
    var label: String
    var pageIndex: Int
    var children: [BookmarkModel]
    var isExpanded: Bool

    init(label: String, pageIndex: Int, children: [BookmarkModel] = []) {
        self.id = UUID()
        self.label = label
        self.pageIndex = pageIndex
        self.children = children
        self.isExpanded = false
    }

    init(from outline: PDFOutline, in document: PDFDocument) {
        self.id = UUID()
        self.label = outline.label ?? "Untitled"
        if let destination = outline.destination, let page = destination.page {
            self.pageIndex = document.index(for: page)
        } else {
            self.pageIndex = 0
        }
        self.isExpanded = outline.isOpen
        self.children = (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            return BookmarkModel(from: child, in: document)
        }
    }

    func toPDFOutline(in document: PDFDocument) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = label
        if let page = document.page(at: pageIndex) {
            outline.destination = PDFDestination(page: page, at: .zero)
        }
        outline.isOpen = isExpanded
        for child in children {
            let childOutline = child.toPDFOutline(in: document)
            outline.insertChild(childOutline, at: outline.numberOfChildren)
        }
        return outline
    }

    static func models(from document: PDFDocument) -> [BookmarkModel] {
        guard let root = document.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).compactMap { index in
            guard let child = root.child(at: index) else { return nil }
            return BookmarkModel(from: child, in: document)
        }
    }
}
