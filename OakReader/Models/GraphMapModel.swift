import Foundation
import OakGraph

/// Lightweight metadata extracted from a GraphDocument JSON file, used for list display.
/// No database — all data lives in JSON files on disk.
struct GraphMapMeta: Identifiable, Hashable {
    let id: UUID
    var title: String
    var graphType: String
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    var displayTitle: String {
        title.isEmpty ? "New Graph" : title
    }

    /// Build from a GraphDocument loaded from disk.
    init(document: GraphDocument, fileDate: Date = Date()) {
        self.id = document.id
        self.title = document.title
        self.graphType = document.graphType.rawValue
        self.isPinned = false
        self.createdAt = fileDate
        self.updatedAt = fileDate
    }

    init(id: UUID = UUID(), title: String = "", graphType: String = "conceptMap",
         isPinned: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.graphType = graphType
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
