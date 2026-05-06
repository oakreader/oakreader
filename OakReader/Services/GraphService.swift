import Foundation
import OakGraph

/// Stateless service for graph map CRUD using JSON files only (no database).
/// Storage layout: ~/OakReader/storage/{storageKey}/graphs/{graphId}.json
struct GraphService {

    // MARK: - Fetch

    /// Scan the graphs directory and return metadata for all graphs, sorted by modification date.
    func fetchGraphs(storageKey: String) -> [GraphMapMeta] {
        let dir = Self.graphsDirectory(storageKey: storageKey)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        ) else { return [] }

        let jsonURLs = urls.filter { $0.pathExtension == "json" }
        var metas: [GraphMapMeta] = []

        for url in jsonURLs {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(GraphDocument.self, from: data) else { continue }

            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            metas.append(GraphMapMeta(document: doc, fileDate: modDate))
        }

        // Sort by date descending
        metas.sort { $0.updatedAt > $1.updatedAt }
        return metas
    }

    // MARK: - Load

    /// Load the full GraphDocument from disk.
    func loadDocument(graphId: UUID, storageKey: String) -> GraphDocument? {
        let url = graphFileURL(graphId: graphId, storageKey: storageKey)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GraphDocument.self, from: data)
    }

    // MARK: - Save

    /// Save (or overwrite) a GraphDocument as a JSON file.
    func saveDocument(_ document: GraphDocument, storageKey: String) throws {
        let graphsDir = Self.graphsDirectory(storageKey: storageKey)
        try FileManager.default.createDirectory(at: graphsDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)

        let url = graphFileURL(graphId: document.id, storageKey: storageKey)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Delete

    func deleteGraph(id: UUID, storageKey: String) {
        let url = graphFileURL(graphId: id, storageKey: storageKey)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    static func graphsDirectory(storageKey: String) -> URL {
        CatalogDatabase.documentDirectory(storageKey: storageKey)
            .appendingPathComponent("graphs", isDirectory: true)
    }

    private func graphFileURL(graphId: UUID, storageKey: String) -> URL {
        Self.graphsDirectory(storageKey: storageKey)
            .appendingPathComponent("\(graphId.uuidString).json")
    }
}
