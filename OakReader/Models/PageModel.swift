import Foundation
import PDFKit

struct PageModel: Identifiable, Equatable {
    let id: UUID
    var pageIndex: Int
    var rotation: Int
    var label: String
    var size: CGSize
    var hasAnnotations: Bool
    var isBookmarked: Bool

    init(pageIndex: Int, page: PDFPage) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.rotation = page.rotation
        self.label = page.label ?? "Page \(pageIndex + 1)"
        let bounds = page.bounds(for: .mediaBox)
        self.size = bounds.size
        self.hasAnnotations = !page.annotations.isEmpty
        self.isBookmarked = false
    }

    init(pageIndex: Int, rotation: Int = 0, label: String? = nil, size: CGSize = PDFDefaults.defaultPageSize) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.rotation = rotation
        self.label = label ?? "Page \(pageIndex + 1)"
        self.size = size
        self.hasAnnotations = false
        self.isBookmarked = false
    }

    static func models(from document: PDFDocument) -> [PageModel] {
        (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return PageModel(pageIndex: index, page: page)
        }
    }
}
