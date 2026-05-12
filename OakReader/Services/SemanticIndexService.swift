import Foundation
import PDFKit
import GRDB

/// On-device semantic search using mlx.embeddings + GRDB vector storage.
/// Documents are chunked and embedded on import; search returns deduplicated
/// results with best-matching excerpts and page references.
final class SemanticIndexService: @unchecked Sendable {
    let embeddingService: EmbeddingService
    let dbQueue: DatabaseQueue

    /// Initialize the service with a loaded EmbeddingService.
    static func create(embeddingService: EmbeddingService, dbQueue: DatabaseQueue) -> SemanticIndexService {
        SemanticIndexService(embeddingService: embeddingService, dbQueue: dbQueue)
    }

    private init(embeddingService: EmbeddingService, dbQueue: DatabaseQueue) {
        self.embeddingService = embeddingService
        self.dbQueue = dbQueue
    }

    // MARK: - Index Item

    /// Extract text from a PDF, chunk it, embed via MLX, and store embeddings as GRDB BLOBs.
    func indexItem(itemId: String, pdfURL: URL) async {
        guard let pdfDoc = PDFDocument(url: pdfURL) else {
            Log.error(Log.semantic, "Cannot open PDF for indexing: \(pdfURL.lastPathComponent)")
            return
        }

        let currentModel = await embeddingService.modelId

        // Skip if already indexed with the current model
        let existingCount = (try? await dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM semantic_chunks
                WHERE item_id = ? AND embedding IS NOT NULL AND embedding_model = ?
                """, arguments: [itemId, currentModel])
        }) ?? 0
        if existingCount > 0 { return }

        // Remove any stale chunks (different model or no embedding)
        try? await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM semantic_chunks WHERE item_id = ?",
                arguments: [itemId]
            )
        }

        let now = Date().iso8601String
        var chunks: [(id: UUID, text: String, type: String, pageStart: Int?, pageEnd: Int?, tokenCount: Int)] = []

        // Chunk 1: Abstract (from citations table if available)
        let abstract: String? = try? await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT abstract FROM citations WHERE item_id = ?", arguments: [itemId])
        }
        if let abstract, !abstract.isEmpty {
            let id = UUID()
            let tokenCount = Self.estimateTokenCount(abstract)
            chunks.append((id: id, text: abstract, type: "abstract", pageStart: nil, pageEnd: nil, tokenCount: tokenCount))
        }

        // Chunk 2+: Page text segments (~500 tokens each, all pages)
        for pageIndex in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIndex), let text = page.string, !text.isEmpty else { continue }
            let segments = Self.chunkText(text, targetTokens: 500)
            for segment in segments {
                let id = UUID()
                let tokenCount = Self.estimateTokenCount(segment)
                chunks.append((id: id, text: segment, type: "page", pageStart: pageIndex, pageEnd: pageIndex, tokenCount: tokenCount))
            }
        }

        guard !chunks.isEmpty else {
            Log.info(Log.semantic, "No text to index for item \(itemId)")
            return
        }

        // Embed all chunks via MLX
        let texts = chunks.map(\.text)
        let embeddings: [[Float]]
        do {
            // Batch in groups to limit memory pressure
            var allEmbeddings: [[Float]] = []
            let batchSize = 32
            for i in stride(from: 0, to: texts.count, by: batchSize) {
                let batch = Array(texts[i..<min(i + batchSize, texts.count)])
                let batchEmbeddings = try await embeddingService.embed(texts: batch)
                allEmbeddings.append(contentsOf: batchEmbeddings)
            }
            embeddings = allEmbeddings
        } catch {
            Log.error(Log.semantic, "MLX embedding failed for item \(itemId): \(error)")
            return
        }

        guard embeddings.count == chunks.count else {
            Log.error(Log.semantic, "Embedding count mismatch for item \(itemId)")
            return
        }

        // Save chunk records with embeddings to GRDB
        do {
            try await dbQueue.write { db in
                for (i, chunk) in chunks.enumerated() {
                    let embeddingData = SemanticChunkRecord.embeddingToData(embeddings[i])
                    var record = SemanticChunkRecord(
                        id: chunk.id.uuidString,
                        itemId: itemId,
                        chunkType: chunk.type,
                        pageStart: chunk.pageStart,
                        pageEnd: chunk.pageEnd,
                        tokenCount: chunk.tokenCount,
                        createdAt: now,
                        embedding: embeddingData,
                        embeddingDim: embeddings[i].count,
                        chunkText: chunk.text,
                        embeddingModel: currentModel,
                        embeddingProvider: "local"
                    )
                    try record.insert(db)
                }
            }
            Log.info(Log.semantic, "Indexed \(chunks.count) chunks for item \(itemId)")
        } catch {
            Log.error(Log.semantic, "Failed to save chunk records for item \(itemId): \(error)")
        }
    }

    // MARK: - Search

    struct SearchResult: Sendable {
        let itemId: String
        let score: Float
        let excerpt: String
        let chunkType: String
        let pageStart: Int?
        let pageEnd: Int?
    }

    /// Search for semantically similar documents, deduplicating by item_id (keep highest score).
    func search(query: String, maxResults: Int = 10, threshold: Float = 0.3) async -> [SearchResult] {
        let currentModel = await embeddingService.modelId

        // Embed the query
        let queryEmbedding: [Float]
        do {
            queryEmbedding = try await embeddingService.embed(text: query)
        } catch {
            Log.error(Log.semantic, "Failed to embed query: \(error)")
            return []
        }

        // Search via VectorSearchEngine
        let hits: [VectorSearchEngine.SearchHit]
        do {
            hits = try await VectorSearchEngine.search(
                queryEmbedding: queryEmbedding,
                dbQueue: dbQueue,
                embeddingModel: currentModel,
                maxResults: maxResults * 3,
                threshold: threshold
            )
        } catch {
            Log.error(Log.semantic, "Vector search failed: \(error)")
            return []
        }

        guard !hits.isEmpty else { return [] }

        // Deduplicate by item_id — keep the highest-scoring chunk per item
        var bestByItem: [String: SearchResult] = [:]
        for hit in hits {
            let result = SearchResult(
                itemId: hit.itemId,
                score: hit.score,
                excerpt: String(hit.chunkText.prefix(300)),
                chunkType: hit.chunkType,
                pageStart: hit.pageStart,
                pageEnd: hit.pageEnd
            )
            if let existing = bestByItem[hit.itemId] {
                if hit.score > existing.score {
                    bestByItem[hit.itemId] = result
                }
            } else {
                bestByItem[hit.itemId] = result
            }
        }

        return Array(bestByItem.values)
            .sorted { $0.score > $1.score }
            .prefix(maxResults)
            .map { $0 }
    }

    // MARK: - Remove Chunks

    /// Remove all chunks for an item from GRDB.
    func removeChunks(forItemId itemId: String) async {
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM semantic_chunks WHERE item_id = ?",
                    arguments: [itemId]
                )
            }
        } catch {
            Log.error(Log.semantic, "Failed to delete chunk records for item \(itemId): \(error)")
        }
    }

    // MARK: - Background Index All

    /// Find unindexed items (or items with outdated embedding model) and index each one.
    func backgroundIndexAll() async {
        let currentModel = await embeddingService.modelId

        let itemsToIndex: [(itemId: String, storageKey: String, attStorageKey: String, fileName: String)]
        do {
            itemsToIndex = try await dbQueue.read { db in
                // Items that either have no chunks or have chunks from a different model
                let rows = try Row.fetchAll(db, sql: """
                    SELECT i.id, i.storage_key, a.storage_key AS att_key, a.file_name
                    FROM items i
                    JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                    LEFT JOIN semantic_chunks sc
                        ON sc.item_id = i.id
                        AND sc.embedding IS NOT NULL
                        AND sc.embedding_model = ?
                    WHERE a.attachment_type = 'pdf' AND sc.id IS NULL
                    """, arguments: [currentModel])
                return rows.map { row in
                    (
                        itemId: row["id"] as String,
                        storageKey: row["storage_key"] as String,
                        attStorageKey: row["att_key"] as String,
                        fileName: row["file_name"] as String
                    )
                }
            }
        } catch {
            Log.error(Log.semantic, "Failed to query unindexed items: \(error)")
            return
        }

        guard !itemsToIndex.isEmpty else {
            Log.info(Log.semantic, "All items already indexed with \(currentModel)")
            return
        }

        Log.info(Log.semantic, "Background indexing \(itemsToIndex.count) items")

        for item in itemsToIndex {
            guard !Task.isCancelled else { break }

            let pdfURL = CatalogDatabase.attachmentFileURL(
                itemStorageKey: item.storageKey,
                attachmentStorageKey: item.attStorageKey,
                fileName: item.fileName
            )
            await indexItem(itemId: item.itemId, pdfURL: pdfURL)

            // Throttle to avoid blocking the system
            try? await Task.sleep(for: .milliseconds(100))
        }

        Log.info(Log.semantic, "Background indexing complete")
    }

    // MARK: - Text Chunking

    /// Split text into segments of approximately `targetTokens` tokens, breaking on sentence boundaries.
    static func chunkText(_ text: String, targetTokens: Int) -> [String] {
        let sentences = splitSentences(text)
        var chunks: [String] = []
        var current = ""
        var currentTokens = 0

        for sentence in sentences {
            let sentenceTokens = estimateTokenCount(sentence)
            if currentTokens + sentenceTokens > targetTokens, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                currentTokens = 0
            }
            current += sentence
            currentTokens += sentenceTokens
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks
    }

    /// Rough token estimate: ~0.75 tokens per character for English text.
    static func estimateTokenCount(_ text: String) -> Int {
        max(1, Int(Double(text.count) * 0.75))
    }

    /// Split text on sentence boundaries (period/question/exclamation followed by whitespace).
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if char == "." || char == "?" || char == "!" {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }

        return sentences
    }
}
