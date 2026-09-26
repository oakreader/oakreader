import Foundation

/// A selection of pages within a document — used by export and any page-range
/// picker UI. Extracted from the (removed) watermark config it originally
/// shipped inside; it outlived that feature.
enum PageRange: Equatable {
    case all
    case range(ClosedRange<Int>)
    case custom([Int])

    var description: String {
        switch self {
        case .all: return "All Pages"
        case .range(let r): return "Pages \(r.lowerBound + 1)–\(r.upperBound + 1)"
        case .custom(let pages): return "Pages: \(pages.map { String($0 + 1) }.joined(separator: ", "))"
        }
    }

    func contains(_ pageIndex: Int) -> Bool {
        switch self {
        case .all: return true
        case .range(let r): return r.contains(pageIndex)
        case .custom(let pages): return pages.contains(pageIndex)
        }
    }
}
