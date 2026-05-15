import Foundation
import GRDB

/// Separate GRDB database for semantic search data (chunks + FTS5).
/// Stored at ~/OakReader/semantic.db — fully regenerable from source content.
final class SemanticDatabase: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    init() throws {
        let dbURL = CatalogDatabase.semanticDatabaseURL
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.foreignKeysEnabled = false // no FK to catalog.db
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-chunks") { db in
            try db.create(table: "chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("item_id", .text).notNull()
                t.column("chunk_type", .text).notNull()
                t.column("page_start", .integer)
                t.column("page_end", .integer)
                t.column("chunk_text", .text).notNull()
                t.column("token_count", .integer)
                t.column("embedding_model", .text).notNull()
                t.column("created_at", .text).notNull()
            }
            try db.create(index: "idx_chunks_item_id", on: "chunks", columns: ["item_id"])

            try db.create(virtualTable: "chunks_fts", using: FTS5()) { t in
                t.synchronize(withTable: "chunks")
                t.tokenizer = .unicode61()
                t.column("chunk_text")
            }
        }

        return migrator
    }

    // MARK: - Destroy All

    /// Delete semantic.db and semantic.usearch for full rebuild (e.g. model switch).
    func destroyAll() throws {
        // Close the current connection by running a checkpoint first
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chunks")
        }

        // Delete the USearch index file
        let indexURL = CatalogDatabase.semanticIndexURL
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try FileManager.default.removeItem(at: indexURL)
        }
    }

    // MARK: - Chunk Operations

    /// Insert chunks and return their assigned rowids (used as USearch keys).
    @discardableResult
    func insertChunks(_ chunks: [SemanticChunk]) throws -> [Int64] {
        try dbQueue.write { db in
            var rowids: [Int64] = []
            for var chunk in chunks {
                try chunk.insert(db)
                guard let id = chunk.id else {
                    throw DatabaseError(message: "Failed to get rowid after insert")
                }
                rowids.append(id)
            }
            return rowids
        }
    }

    /// Delete all chunks for an item. Returns the deleted rowids (for USearch cleanup).
    @discardableResult
    func deleteChunks(forItemId itemId: String) throws -> [Int64] {
        try dbQueue.write { db in
            let rowids = try Int64.fetchAll(db, sql: "SELECT id FROM chunks WHERE item_id = ?", arguments: [itemId])
            try db.execute(sql: "DELETE FROM chunks WHERE item_id = ?", arguments: [itemId])
            return rowids
        }
    }

    /// Fetch chunk texts and metadata by rowids.
    func fetchChunks(byIds ids: [Int64]) throws -> [SemanticChunk] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return try SemanticChunk.fetchAll(db, sql: """
                SELECT * FROM chunks WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
        }
    }

    /// Count chunks for an item with a specific embedding model.
    func chunkCount(forItemId itemId: String, embeddingModel: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chunks WHERE item_id = ? AND embedding_model = ?
                """, arguments: [itemId, embeddingModel]) ?? 0
        }
    }

    /// Get all indexed item IDs.
    func indexedItemIds(embeddingModel: String) throws -> Set<String> {
        try dbQueue.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT DISTINCT item_id FROM chunks WHERE embedding_model = ?
                """, arguments: [embeddingModel])
            return Set(ids)
        }
    }

    // MARK: - Index Stats

    struct IndexStats {
        let indexedItemCount: Int
        let totalChunkCount: Int
        let embeddingModel: String?
    }

    func indexStats() throws -> IndexStats {
        try dbQueue.read { db in
            let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT item_id) FROM chunks") ?? 0
            let chunkCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
            let model = try String.fetchOne(db, sql: "SELECT embedding_model FROM chunks LIMIT 1")
            return IndexStats(indexedItemCount: itemCount, totalChunkCount: chunkCount, embeddingModel: model)
        }
    }

    // MARK: - FTS5 Search

    /// BM25 keyword search on chunk text. Returns rowids ordered by relevance.
    func bm25Search(query: String, maxResults: Int = 50) throws -> [Int64] {
        try dbQueue.read { db in
            // Escape FTS5 special characters and build a simple query
            let sanitized = Self.sanitizeFTS5Query(query)
            guard !sanitized.isEmpty else { return [] }

            return try Int64.fetchAll(db, sql: """
                SELECT rowid FROM chunks_fts
                WHERE chunks_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [sanitized, maxResults])
        }
    }

    /// Sanitize a user query for FTS5 MATCH syntax.
    private static func sanitizeFTS5Query(_ query: String) -> String {
        // Split into words, wrap each in quotes to treat as literal terms
        let words = query.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        // Use implicit AND: each word is quoted
        return words.map { "\"\($0)\"" }.joined(separator: " ")
    }
}

// MARK: - SemanticChunk Model

struct SemanticChunk: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chunks"

    var id: Int64?          // auto-increment rowid = USearch key
    var itemId: String
    var chunkType: String   // "abstract", "page", "section"
    var pageStart: Int?
    var pageEnd: Int?
    var chunkText: String
    var tokenCount: Int?
    var embeddingModel: String
    var createdAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case itemId = "item_id"
        case chunkType = "chunk_type"
        case pageStart = "page_start"
        case pageEnd = "page_end"
        case chunkText = "chunk_text"
        case tokenCount = "token_count"
        case embeddingModel = "embedding_model"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
