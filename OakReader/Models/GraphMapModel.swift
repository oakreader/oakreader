import Foundation
import OakGraph

/// Lightweight metadata extracted from a GraphDocument JSON file, used for list display.
/// No database — all data lives in JSON files on disk.
struct GraphMapMeta: Identifiable {
    let id: UUID
    var title: String
    var graphType: String
    var createdAt: Date
    var updatedAt: Date
    var thumbnailData: Data?

    var displayTitle: String {
        title.isEmpty ? "New Graph" : title
    }

    /// Descriptive filename: `{slug}-{type}.oakgraph`
    var fileName: String {
        let slug = Self.slug(from: title, fallback: id.uuidString)
        let typeSuffix = graphType == "mindMap" ? "mindmap" : "concept-map"
        return "\(slug)-\(typeSuffix).oakgraph"
    }

    /// Thumbnail filename: `{slug}-{type}.thumb.png`
    var thumbnailFileName: String {
        let slug = Self.slug(from: title, fallback: id.uuidString)
        let typeSuffix = graphType == "mindMap" ? "mindmap" : "concept-map"
        return "\(slug)-\(typeSuffix).thumb.png"
    }

    /// Build from a GraphDocument loaded from disk.
    init(document: GraphDocument, fileDate: Date = Date()) {
        self.id = document.id
        self.title = document.title
        self.graphType = document.graphType.rawValue
        self.createdAt = fileDate
        self.updatedAt = fileDate
    }

    init(id: UUID = UUID(), title: String = "", graphType: String = "conceptMap",
         createdAt: Date = Date(), updatedAt: Date = Date(), thumbnailData: Data? = nil) {
        self.id = id
        self.title = title
        self.graphType = graphType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.thumbnailData = thumbnailData
    }

    /// Generate a URL-safe slug from a title.
    static func slug(from title: String, fallback: String) -> String {
        let lowered = title.lowercased()
        let cleaned = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        let slug = String(cleaned).replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return slug.isEmpty ? fallback : slug
    }
}

// MARK: - Hashable (by id only — excludes thumbnailData)

extension GraphMapMeta: Hashable {
    static func == (lhs: GraphMapMeta, rhs: GraphMapMeta) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
