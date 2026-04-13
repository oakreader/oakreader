import Foundation
import AppKit
import PDFKit

struct ComparisonResult: Identifiable {
    let id: UUID
    var pageIndex: Int
    var differences: [Difference]
    var diffImage: NSImage?

    struct Difference: Identifiable {
        let id: UUID
        var type: DifferenceType
        var bounds: CGRect
        var description: String

        init(type: DifferenceType, bounds: CGRect, description: String) {
            self.id = UUID()
            self.type = type
            self.bounds = bounds
            self.description = description
        }
    }

    enum DifferenceType: String {
        case textAdded
        case textRemoved
        case textChanged
        case imageChanged
        case annotationChanged

        var color: NSColor {
            switch self {
            case .textAdded: return .systemGreen
            case .textRemoved: return .systemRed
            case .textChanged: return .systemBlue
            case .imageChanged: return .systemOrange
            case .annotationChanged: return .systemPurple
            }
        }

        var label: String {
            switch self {
            case .textAdded: return "Added"
            case .textRemoved: return "Removed"
            case .textChanged: return "Changed"
            case .imageChanged: return "Image Changed"
            case .annotationChanged: return "Annotation Changed"
            }
        }
    }

    init(pageIndex: Int) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.differences = []
        self.diffImage = nil
    }

    var hasDifferences: Bool { !differences.isEmpty }
    var addedCount: Int { differences.filter { $0.type == .textAdded }.count }
    var removedCount: Int { differences.filter { $0.type == .textRemoved }.count }
    var changedCount: Int { differences.filter { $0.type == .textChanged || $0.type == .imageChanged }.count }
}
