import Foundation
import GRDB

/// Separate GRDB database for full-text search data (chunks + FTS5 BM25).
/// Stored at ~/OakReader/semantic.sqlite — fully regenerable from source content.
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
        // This database is a regenerable cache: if the schema definition changes,
        // wipe and rebuild from source content rather than writing a migration.
        migrator.eraseDatabaseOnSchemaChange = true

        migrator.registerMigration("v1-chunks") { db in
            try db.create(table: "chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("item_id", .text).notNull()
                t.column("chunk_type", .text).notNull()
                t.column("page_start", .integer)
                t.column("page_end", .integer)
                t.column("chunk_text", .text).notNull()
                t.column("token_count", .integer)
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

    /// Delete all chunks for a full rebuild (e.g. from the Rebuild Index button).
    func destroyAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chunks")
        }
    }

    // MARK: - Chunk Operations

    /// Insert chunks. Returns their assigned rowids.
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

    /// Delete all chunks for an item.
    func deleteChunks(forItemId itemId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chunks WHERE item_id = ?", arguments: [itemId])
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

    /// Count chunks for an item.
    func chunkCount(forItemId itemId: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks WHERE item_id = ?", arguments: [itemId]) ?? 0
        }
    }

    /// Get all indexed item IDs.
    func indexedItemIds() throws -> Set<String> {
        try dbQueue.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM chunks")
            return Set(ids)
        }
    }

    // MARK: - Index Stats

    struct IndexStats {
        let indexedItemCount: Int
        let totalChunkCount: Int
    }

    func indexStats() throws -> IndexStats {
        try dbQueue.read { db in
            let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT item_id) FROM chunks") ?? 0
            let chunkCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
            return IndexStats(indexedItemCount: itemCount, totalChunkCount: chunkCount)
        }
    }

    // MARK: - FTS5 Search

    /// A BM25-ranked full-text hit: chunk rowid plus a relevance score (higher = better).
    struct Hit: Sendable {
        let chunkId: Int64
        let score: Double
    }

    /// BM25 keyword search on chunk text, ordered by relevance.
    func bm25Search(query: String, maxResults: Int = 50) throws -> [Hit] {
        try dbQueue.read { db in
            let sanitized = Self.sanitizeFTS5Query(query)
            guard !sanitized.isEmpty else { return [] }

            // FTS5 bm25() returns lower (more negative) values for better matches;
            // negate so higher = more relevant for downstream sorting.
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, bm25(chunks_fts) AS score FROM chunks_fts
                WHERE chunks_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [sanitized, maxResults])
            return rows.map { Hit(chunkId: $0["rowid"], score: -($0["score"] as Double)) }
        }
    }

    /// Sanitize a user query for FTS5 MATCH syntax.
    private static func sanitizeFTS5Query(_ query: String) -> String {
        // Split into words, wrap each in quotes to treat as literal terms (implicit AND).
        let words = query.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        return words.map { "\"\($0)\"" }.joined(separator: " ")
    }
}

// MARK: - SemanticChunk Model

struct SemanticChunk: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chunks"

    var id: Int64?
    var itemId: String
    var chunkType: String   // "abstract", "page", "section"
    var pageStart: Int?
    var pageEnd: Int?
    var chunkText: String
    var tokenCount: Int?
    var createdAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case itemId = "item_id"
        case chunkType = "chunk_type"
        case pageStart = "page_start"
        case pageEnd = "page_end"
        case chunkText = "chunk_text"
        case tokenCount = "token_count"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
