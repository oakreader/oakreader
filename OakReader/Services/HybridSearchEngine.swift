import Foundation
import USearch

/// Hybrid search combining USearch HNSW vector index + FTS5 BM25 keyword search,
/// merged via Reciprocal Rank Fusion (RRF).
final class HybridSearchEngine: @unchecked Sendable {
    private var index: USearchIndex?
    private let semanticDB: SemanticDatabase
    private let dimensions: UInt32
    private let indexPath: String

    struct SearchHit: Sendable {
        let chunkId: Int64
        let score: Float
    }

    init(semanticDB: SemanticDatabase, dimensions: UInt32 = 1024) {
        self.semanticDB = semanticDB
        self.dimensions = dimensions
        self.indexPath = CatalogDatabase.semanticIndexURL.path
        loadOrCreateIndex()
    }

    // MARK: - Index Management

    private func loadOrCreateIndex() {
        let idx = USearchIndex.make(
            metric: .cos,
            dimensions: dimensions,
            connectivity: 16,
            quantization: .F32,
            multi: false
        )
        if FileManager.default.fileExists(atPath: indexPath) {
            idx.load(path: indexPath)
        }
        index = idx
    }

    /// Add a vector with its chunk rowid as key.
    func addVector(key: UInt64, vector: [Float]) {
        guard let index else { return }
        index.add(key: USearchKey(key), vector: vector)
    }

    /// Remove vectors by keys.
    func removeVectors(keys: [UInt64]) {
        guard let index else { return }
        for key in keys {
            index.remove(key: USearchKey(key))
        }
    }

    /// Persist the USearch index to disk.
    func save() {
        guard let index else { return }
        index.save(path: indexPath)
    }

    /// Reset the index for a full rebuild (e.g. model switch).
    func reset() {
        index?.clear()
        if FileManager.default.fileExists(atPath: indexPath) {
            try? FileManager.default.removeItem(atPath: indexPath)
        }
        loadOrCreateIndex()
    }

    /// Reinitialize with new dimensions (e.g. different embedding model).
    func reinitialize(dimensions newDimensions: UInt32) {
        let idx = USearchIndex.make(
            metric: .cos,
            dimensions: newDimensions,
            connectivity: 16,
            quantization: .F32,
            multi: false
        )
        index = idx
    }

    // MARK: - Hybrid Search

    /// Search using both vector similarity and BM25 keyword matching, merged with RRF.
    func search(queryEmbedding: [Float], queryText: String, maxResults: Int = 10) throws -> [SearchHit] {
        var scores: [Int64: Float] = [:]
        let k: Float = 60

        // 1. Vector search via USearch
        if let index, !index.isEmpty {
            let vectorCount = min(50, index.count)
            let (keys, _) = index.search(vector: queryEmbedding, count: vectorCount)

            for (rank, key) in keys.enumerated() {
                let chunkId = Int64(bitPattern: key)
                scores[chunkId, default: 0] += 1 / (k + Float(rank + 1))
            }
        }

        // 2. BM25 keyword search via FTS5
        if let bm25Results = try? semanticDB.bm25Search(query: queryText, maxResults: 50) {
            for (rank, chunkId) in bm25Results.enumerated() {
                scores[chunkId, default: 0] += 1 / (k + Float(rank + 1))
            }
        }

        // 3. Sort by RRF score and return top-K
        let sorted = scores.sorted { $0.value > $1.value }
            .prefix(maxResults)
            .map { SearchHit(chunkId: $0.key, score: $0.value) }

        return Array(sorted)
    }
}
