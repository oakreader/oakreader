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
            var meta = GraphMapMeta(document: doc, fileDate: modDate)

            // Load thumbnail if it exists
            meta.thumbnailData = loadThumbnail(graphId: doc.id, storageKey: storageKey)

            metas.append(meta)

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
        deleteThumbnail(graphId: id, storageKey: storageKey)
    }

    // MARK: - Thumbnails

    /// Save a thumbnail PNG for the given graph.
    func saveThumbnail(_ data: Data, for document: GraphDocument, storageKey: String) {
        let dir = Self.graphsDirectory(storageKey: storageKey)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Remove old thumbnail if filename changed (e.g. title rename)
        deleteThumbnail(graphId: document.id, storageKey: storageKey)

        let slug = GraphMapMeta.slug(from: document.title, fallback: document.id.uuidString)
        let typeSuffix = document.graphType == .mindMap ? "mindmap" : "concept-map"
        let filename = "\(slug)-\(typeSuffix).thumb.png"
        let url = dir.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
    }

    /// Load the thumbnail for a graph by scanning for its .thumb.png file.
    func loadThumbnail(graphId: UUID, storageKey: String) -> Data? {
        let dir = Self.graphsDirectory(storageKey: storageKey)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return nil }

        // Find the .oakgraph file to derive the thumbnail name
        let graphFiles = urls.filter { $0.pathExtension == "oakgraph" || $0.pathExtension == "json" }
        for graphURL in graphFiles {
            guard let data = try? Data(contentsOf: graphURL),
                  let doc = try? JSONDecoder().decode(GraphDocument.self, from: data),
                  doc.id == graphId else { continue }

            let slug = GraphMapMeta.slug(from: doc.title, fallback: doc.id.uuidString)
            let typeSuffix = doc.graphType == .mindMap ? "mindmap" : "concept-map"
            let thumbName = "\(slug)-\(typeSuffix).thumb.png"
            let thumbURL = dir.appendingPathComponent(thumbName)
            return try? Data(contentsOf: thumbURL)
        }
        return nil
    }

    /// Delete the thumbnail file for a graph.
    func deleteThumbnail(graphId: UUID, storageKey: String) {
        let dir = Self.graphsDirectory(storageKey: storageKey)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        let thumbFiles = urls.filter { $0.lastPathComponent.hasSuffix(".thumb.png") }
        // Remove any thumb whose base name matches a graph file for this ID
        // Simpler: just remove all .thumb.png that share the same slug prefix
        // We scan graph files to find the right slug
        let graphFiles = urls.filter { $0.pathExtension == "oakgraph" || $0.pathExtension == "json" }
        for graphURL in graphFiles {
            guard let data = try? Data(contentsOf: graphURL),
                  let doc = try? JSONDecoder().decode(GraphDocument.self, from: data),
                  doc.id == graphId else { continue }

            let slug = GraphMapMeta.slug(from: doc.title, fallback: doc.id.uuidString)
            let typeSuffix = doc.graphType == .mindMap ? "mindmap" : "concept-map"
            let thumbName = "\(slug)-\(typeSuffix).thumb.png"
            let thumbURL = dir.appendingPathComponent(thumbName)
            try? FileManager.default.removeItem(at: thumbURL)
            return
        }

        // Fallback: if graph file already deleted, remove any orphaned thumb by UUID prefix
        for thumbURL in thumbFiles {
            let name = thumbURL.lastPathComponent
            if name.contains(graphId.uuidString.lowercased()) {
                try? FileManager.default.removeItem(at: thumbURL)
            }
        }
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
