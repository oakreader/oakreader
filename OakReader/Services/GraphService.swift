import Foundation
import OakGraph

/// Stateless service for graph map CRUD using JSON files only (no database).
/// Storage layout: ~/OakReader/storage/{storageKey}/graphs/{slug}-{type}.oakgraph
struct GraphService {

    // MARK: - Fetch

    /// Scan the graphs directory and return metadata for all graphs, sorted by modification date.
    func fetchGraphs(storageKey: String) -> [GraphMapMeta] {
        let dir = Self.graphsDirectory(storageKey: storageKey)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        ) else { return [] }

        let graphURLs = urls.filter { $0.pathExtension == "oakgraph" || $0.pathExtension == "json" }
        var metas: [GraphMapMeta] = []

        for url in graphURLs {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(GraphDocument.self, from: data) else { continue }

            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            metas.append(GraphMapMeta(document: doc, fileDate: modDate))

            // Migrate legacy .json files to .oakgraph
            if url.pathExtension == "json" {
                let newURL = graphFileURL(for: doc, storageKey: storageKey)
                try? FileManager.default.moveItem(at: url, to: newURL)
            }
        }

        // Sort by date descending
        metas.sort { $0.updatedAt > $1.updatedAt }
        return metas
    }

    // MARK: - Load

    /// Load the full GraphDocument from disk.
    func loadDocument(graphId: UUID, storageKey: String) -> GraphDocument? {
        guard let url = findGraphFile(graphId: graphId, storageKey: storageKey),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GraphDocument.self, from: data)
    }

    // MARK: - Save

    /// Save (or overwrite) a GraphDocument as an .oakgraph file.
    func saveDocument(_ document: GraphDocument, storageKey: String) throws {
        let graphsDir = Self.graphsDirectory(storageKey: storageKey)
        try FileManager.default.createDirectory(at: graphsDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)

        // Remove any old file for this graph ID (handles renames)
        if let oldURL = findGraphFile(graphId: document.id, storageKey: storageKey) {
            let newURL = graphFileURL(for: document, storageKey: storageKey)
            if oldURL != newURL {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }

        let url = graphFileURL(for: document, storageKey: storageKey)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Delete

    func deleteGraph(id: UUID, storageKey: String) {
        guard let url = findGraphFile(graphId: id, storageKey: storageKey) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    static func graphsDirectory(storageKey: String) -> URL {
        CatalogDatabase.documentDirectory(storageKey: storageKey)
            .appendingPathComponent("graphs", isDirectory: true)
    }

    /// Descriptive filename: `{slug}-{type}.oakgraph`
    func graphFileURL(for document: GraphDocument, storageKey: String) -> URL {
        let slug = GraphMapMeta.slug(from: document.title, fallback: document.id.uuidString)
        let typeSuffix = document.graphType == .mindMap ? "mindmap" : "concept-map"
        let filename = "\(slug)-\(typeSuffix).oakgraph"
        return Self.graphsDirectory(storageKey: storageKey)
            .appendingPathComponent(filename)
    }

    /// Find the on-disk file for a graph by scanning the directory for a matching graph ID.
    /// Handles both old `.json` and new `.oakgraph` files, and supports renamed filenames.
    private func findGraphFile(graphId: UUID, storageKey: String) -> URL? {
        let dir = Self.graphsDirectory(storageKey: storageKey)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return nil }

        let candidates = urls.filter { $0.pathExtension == "oakgraph" || $0.pathExtension == "json" }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(GraphDocument.self, from: data),
                  doc.id == graphId else { continue }
            return url
        }
        return nil
    }
}
