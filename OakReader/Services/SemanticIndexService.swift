import Foundation
import PDFKit
import GRDB

/// On-device semantic search using MLXEmbedders + USearch HNSW + FTS5 BM25.
/// Documents are chunked (heading-aware for markdown, sentence-boundary for others)
/// and indexed into semantic.sqlite + semantic.usearch on import.
/// Search uses hybrid RRF to merge vector and keyword results.
final class SemanticIndexService: @unchecked Sendable {
    let embeddingService: EmbeddingService
    let semanticDB: SemanticDatabase
    let searchEngine: HybridSearchEngine
    let catalogDBQueue: DatabaseQueue

    static func create(
        embeddingService: EmbeddingService,
        semanticDB: SemanticDatabase,
        searchEngine: HybridSearchEngine,
        catalogDBQueue: DatabaseQueue
    ) -> SemanticIndexService {
        SemanticIndexService(
            embeddingService: embeddingService,
            semanticDB: semanticDB,
            searchEngine: searchEngine,
            catalogDBQueue: catalogDBQueue
        )
    }

    private init(
        embeddingService: EmbeddingService,
        semanticDB: SemanticDatabase,
        searchEngine: HybridSearchEngine,
        catalogDBQueue: DatabaseQueue
    ) {
        self.embeddingService = embeddingService
        self.semanticDB = semanticDB
        self.searchEngine = searchEngine
        self.catalogDBQueue = catalogDBQueue
    }

    // MARK: - Public Index API

    /// Index an item by type. Routes to the appropriate text extractor and chunker.
    func indexItem(itemId: String, contentType: String, storageKey: String, attStorageKey: String, fileName: String) async {
        let currentModel = await embeddingService.modelId

        // Skip if already indexed with the current model
        if let count = try? semanticDB.chunkCount(forItemId: itemId, embeddingModel: currentModel), count > 0 {
            return
        }

        // Remove any stale chunks (different model)
        if let deletedIds = try? semanticDB.deleteChunks(forItemId: itemId), !deletedIds.isEmpty {
            searchEngine.removeVectors(keys: deletedIds.map { UInt64(bitPattern: $0) })
        }

        // Extract text chunks based on content type
        var chunks = await extractAbstract(itemId: itemId)

        let fileURL = CatalogDatabase.attachmentFileURL(
            itemStorageKey: storageKey,
            attachmentStorageKey: attStorageKey,
            fileName: fileName
        )
        let attDir = CatalogDatabase.attachmentDirectory(
            itemStorageKey: storageKey,
            attachmentStorageKey: attStorageKey
        )

        switch contentType {
        case "pdf":
            chunks += extractPDFChunks(pdfURL: fileURL)
        case "html":
            chunks += extractHTMLChunks(attachmentDir: attDir, htmlURL: fileURL)
        case "markdown":
            chunks += extractMarkdownChunks(fileURL: fileURL)
        case "video":
            chunks += extractEmbedTextChunks(attachmentDir: attDir)
        default:
            break
        }

        guard !chunks.isEmpty else {
            Log.info(Log.semantic, "No text to index for item \(itemId)")
            return
        }

        await embedAndStore(itemId: itemId, chunks: chunks, model: currentModel)
    }

    // MARK: - Text Extraction

    /// Extract abstract from catalog.db citations table if available.
    private func extractAbstract(itemId: String) async -> [ContentChunker.Chunk] {
        let abstract: String? = try? await catalogDBQueue.read { db in
            try String.fetchOne(db, sql: "SELECT abstract FROM citations WHERE item_id = ?", arguments: [itemId])
        }
        guard let abstract, !abstract.isEmpty else { return [] }
        return [ContentChunker.Chunk(text: abstract, type: "abstract", pageStart: nil, pageEnd: nil)]
    }

    /// Extract chunks from a PDF document.
    private func extractPDFChunks(pdfURL: URL) -> [ContentChunker.Chunk] {
        guard let pdfDoc = PDFDocument(url: pdfURL) else {
            Log.error(Log.semantic, "Cannot open PDF: \(pdfURL.lastPathComponent)")
            return []
        }
        var chunks: [ContentChunker.Chunk] = []
        for pageIndex in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIndex), let text = page.string, !text.isEmpty else { continue }
            chunks += ContentChunker.chunkPlainText(text, type: "page", pageStart: pageIndex, pageEnd: pageIndex)
        }
        return chunks
    }

    /// Extract chunks from an HTML document: prefer content.md (heading-aware), fall back to HTML.
    private func extractHTMLChunks(attachmentDir: URL, htmlURL: URL) -> [ContentChunker.Chunk] {
        let mdURL = attachmentDir.appendingPathComponent("content.md")

        if let md = try? String(contentsOf: mdURL, encoding: .utf8), !md.isEmpty {
            return ContentChunker.chunkMarkdown(md)
        }

        if let data = try? Data(contentsOf: htmlURL) {
            let text = HTMLTextExtractor.extractText(from: data)
            if !text.isEmpty {
                return ContentChunker.chunkPlainText(text)
            }
        }

        return []
    }

    /// Extract chunks from a markdown file using heading-aware chunking.
    private func extractMarkdownChunks(fileURL: URL) -> [ContentChunker.Chunk] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty else {
            return []
        }
        return ContentChunker.chunkMarkdown(text)
    }

    /// Extract chunks from all .md and .txt files in an embed's attachment directory.
    private func extractEmbedTextChunks(attachmentDir: URL) -> [ContentChunker.Chunk] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: attachmentDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var chunks: [ContentChunker.Chunk] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = file.pathExtension.lowercased()
            guard ext == "md" || ext == "txt" else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { continue }

            if ext == "md" {
                chunks += ContentChunker.chunkMarkdown(text)
            } else {
                chunks += ContentChunker.chunkPlainText(text)
            }
        }
        return chunks
    }

    // MARK: - Embed & Store

    private static let batchSize = 64

    private func embedAndStore(itemId: String, chunks: [ContentChunker.Chunk], model: String) async {
        let now = Date().iso8601String
        var totalIndexed = 0

        for batchStart in stride(from: 0, to: chunks.count, by: Self.batchSize) {
            let batchEnd = min(batchStart + Self.batchSize, chunks.count)
            let batchChunks = Array(chunks[batchStart..<batchEnd])
            let batchTexts = batchChunks.map(\.text)

            // Embed this batch
            let batchEmbeddings: [[Float]]
            do {
                batchEmbeddings = try await embeddingService.embed(texts: batchTexts)
            } catch {
                Log.error(Log.semantic, "MLX embedding failed for item \(itemId) batch \(batchStart): \(error)")
                return
            }

            guard batchEmbeddings.count == batchChunks.count else {
                Log.error(Log.semantic, "Embedding count mismatch for item \(itemId) batch \(batchStart)")
                return
            }

            // Insert this batch into DB and index immediately, then release embeddings
            do {
                let records = batchChunks.enumerated().map { i, chunk in
                    SemanticChunk(
                        id: nil,
                        itemId: itemId,
                        chunkType: chunk.type,
                        pageStart: chunk.pageStart,
                        pageEnd: chunk.pageEnd,
                        chunkText: chunk.text,
                        tokenCount: ContentChunker.estimateTokenCount(chunk.text),
                        embeddingModel: model,
                        createdAt: now
                    )
                }

                let rowids = try semanticDB.insertChunks(records)
                for (i, rowid) in rowids.enumerated() {
                    searchEngine.addVector(key: UInt64(bitPattern: rowid), vector: batchEmbeddings[i])
                }
                totalIndexed += batchChunks.count
            } catch {
                Log.error(Log.semantic, "Failed to save chunk records for item \(itemId): \(error)")
                return
            }
        }

        if totalIndexed > 0 {
            searchEngine.save()
            Log.info(Log.semantic, "Indexed \(totalIndexed) chunks for item \(itemId)")
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

    /// Search using hybrid RRF (vector + BM25), deduplicating by item_id (keep highest score).
    func search(query: String, maxResults: Int = 10) async -> [SearchResult] {
        let queryEmbedding: [Float]
        do {
            queryEmbedding = try await embeddingService.embed(text: query)
        } catch {
            Log.error(Log.semantic, "Failed to embed query: \(error)")
            return []
        }

        let hits: [HybridSearchEngine.SearchHit]
        do {
            hits = try searchEngine.search(
                queryEmbedding: queryEmbedding,
                queryText: query,
                maxResults: maxResults * 3
            )
        } catch {
            Log.error(Log.semantic, "Hybrid search failed: \(error)")
            return []
        }

        guard !hits.isEmpty else { return [] }

        // Fetch chunk metadata from semantic.sqlite
        let chunkIds = hits.map(\.chunkId)
        let scoreMap = Dictionary(uniqueKeysWithValues: hits.map { ($0.chunkId, $0.score) })

        let chunks: [SemanticChunk]
        do {
            chunks = try semanticDB.fetchChunks(byIds: chunkIds)
        } catch {
            Log.error(Log.semantic, "Failed to fetch chunks: \(error)")
            return []
        }

        // Deduplicate by item_id, keeping highest score
        var bestByItem: [String: SearchResult] = [:]
        for chunk in chunks {
            guard let chunkId = chunk.id else { continue }
            let score = scoreMap[chunkId] ?? 0
            let result = SearchResult(
                itemId: chunk.itemId,
                score: score,
                excerpt: String(chunk.chunkText.prefix(300)),
                chunkType: chunk.chunkType,
                pageStart: chunk.pageStart,
                pageEnd: chunk.pageEnd
            )
            if let existing = bestByItem[chunk.itemId] {
                if score > existing.score {
                    bestByItem[chunk.itemId] = result
                }
            } else {
                bestByItem[chunk.itemId] = result
            }
        }

        return Array(bestByItem.values)
            .sorted { $0.score > $1.score }
            .prefix(maxResults)
            .map { $0 }
    }

    // MARK: - Remove Chunks

    func removeChunks(forItemId itemId: String) async {
        do {
            let deletedIds = try semanticDB.deleteChunks(forItemId: itemId)
            if !deletedIds.isEmpty {
                searchEngine.removeVectors(keys: deletedIds.map { UInt64(bitPattern: $0) })
                searchEngine.save()
            }
        } catch {
            Log.error(Log.semantic, "Failed to delete chunk records for item \(itemId): \(error)")
        }
    }

    // MARK: - Background Index All

    private struct UnindexedItem {
        let itemId: String
        let storageKey: String
        let attStorageKey: String
        let fileName: String
        let contentType: String
    }

    /// Find unindexed items (or items with outdated embedding model) and index each one.
    func backgroundIndexAll() async {
        let currentModel = await embeddingService.modelId

        // Get already-indexed item IDs from semantic.sqlite
        let indexedIds: Set<String>
        do {
            indexedIds = try semanticDB.indexedItemIds(embeddingModel: currentModel)
        } catch {
            Log.error(Log.semantic, "Failed to query indexed items: \(error)")
            return
        }

        // Get all indexable items from catalog.db, recently opened first
        let allItems: [UnindexedItem]
        do {
            allItems = try await catalogDBQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT i.id, i.storage_key, a.storage_key AS att_key, a.file_name, a.content_type
                    FROM items i
                    JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                    WHERE a.content_type IN ('pdf', 'html', 'markdown', 'video')
                    ORDER BY
                        CASE WHEN i.last_opened_at IS NOT NULL THEN 0 ELSE 1 END,
                        i.last_opened_at DESC,
                        i.created_at DESC
                    """)
                return rows.map { row in
                    UnindexedItem(
                        itemId: row["id"] as String,
                        storageKey: row["storage_key"] as String,
                        attStorageKey: row["att_key"] as String,
                        fileName: row["file_name"] as String,
                        contentType: row["content_type"] as String
                    )
                }
            }
        } catch {
            Log.error(Log.semantic, "Failed to query items: \(error)")
            return
        }

        let itemsToIndex = allItems.filter { !indexedIds.contains($0.itemId) }

        guard !itemsToIndex.isEmpty else {
            Log.info(Log.semantic, "All items already indexed with \(currentModel)")
            return
        }

        Log.info(Log.semantic, "Background indexing \(itemsToIndex.count) items")

        for item in itemsToIndex {
            guard !Task.isCancelled else { break }

            await indexItem(
                itemId: item.itemId,
                contentType: item.contentType,
                storageKey: item.storageKey,
                attStorageKey: item.attStorageKey,
                fileName: item.fileName
            )

            try? await Task.sleep(for: .milliseconds(100))
        }

        Log.info(Log.semantic, "Background indexing complete")
    }

    /// Index specific items by their IDs (for manual collection embedding).
    func indexItems(_ itemIds: [String]) async {
        let currentModel = await embeddingService.modelId

        let itemsToIndex: [UnindexedItem]
        do {
            let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
            itemsToIndex = try await catalogDBQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT i.id, i.storage_key, a.storage_key AS att_key, a.file_name, a.content_type
                    FROM items i
                    JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                    WHERE a.content_type IN ('pdf', 'html', 'markdown', 'video')
                      AND i.id IN (\(placeholders))
                    """, arguments: StatementArguments(itemIds))
                return rows.map { row in
                    UnindexedItem(
                        itemId: row["id"] as String,
                        storageKey: row["storage_key"] as String,
                        attStorageKey: row["att_key"] as String,
                        fileName: row["file_name"] as String,
                        contentType: row["content_type"] as String
                    )
                }
            }
        } catch {
            Log.error(Log.semantic, "Failed to query items for collection embedding: \(error)")
            return
        }

        Log.info(Log.semantic, "Embedding \(itemsToIndex.count) items from collection")

        for item in itemsToIndex {
            guard !Task.isCancelled else { break }

            // Force re-index: delete existing chunks first
            if let deletedIds = try? semanticDB.deleteChunks(forItemId: item.itemId), !deletedIds.isEmpty {
                searchEngine.removeVectors(keys: deletedIds.map { UInt64(bitPattern: $0) })
            }

            // Extract text chunks
            var chunks = await extractAbstract(itemId: item.itemId)

            let fileURL = CatalogDatabase.attachmentFileURL(
                itemStorageKey: item.storageKey,
                attachmentStorageKey: item.attStorageKey,
                fileName: item.fileName
            )
            let attDir = CatalogDatabase.attachmentDirectory(
                itemStorageKey: item.storageKey,
                attachmentStorageKey: item.attStorageKey
            )

            switch item.contentType {
            case "pdf":
                chunks += extractPDFChunks(pdfURL: fileURL)
            case "html":
                chunks += extractHTMLChunks(attachmentDir: attDir, htmlURL: fileURL)
            case "markdown":
                chunks += extractMarkdownChunks(fileURL: fileURL)
            case "video":
                chunks += extractEmbedTextChunks(attachmentDir: attDir)
            default:
                break
            }

            guard !chunks.isEmpty else { continue }
            await embedAndStore(itemId: item.itemId, chunks: chunks, model: currentModel)

            try? await Task.sleep(for: .milliseconds(100))
        }

        Log.info(Log.semantic, "Collection embedding complete")
    }
}
