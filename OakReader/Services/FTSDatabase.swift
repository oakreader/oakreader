import Foundation
import GRDB

/// Separate GRDB database for full-text search data (chunks + FTS5 BM25).
/// Stored at ~/OakReader/search.sqlite — fully regenerable from source content.
final class FTSDatabase: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    init() throws {
        let dbURL = CatalogDatabase.searchDatabaseURL
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Clean up regenerable caches left by older builds: the pre-FTS5 vector index
        // and the previous semantic.sqlite (this DB was renamed to search.sqlite). Both
        // are fully regenerable, so they're deleted rather than migrated. Best-effort —
        // failure here must not block opening the DB.
        let dataDir = dbURL.deletingLastPathComponent()
        for legacy in ["semantic.usearch", "semantic.sqlite", "semantic.sqlite-wal", "semantic.sqlite-shm"] {
            try? FileManager.default.removeItem(at: dataDir.appendingPathComponent(legacy))
        }

        var config = Configuration()
        config.foreignKeysEnabled = false // no FK to catalog.db
        // The index is opened on more than one connection (background indexing +
        // the settings stats poll / Rebuild button). Use WAL + a busy timeout so a
        // Rebuild's DELETE waits for an in-flight indexing write instead of failing
        // immediately with SQLITE_BUSY.
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
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
    func insertChunks(_ chunks: [FTSChunk]) throws -> [Int64] {
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
    func fetchChunks(byIds ids: [Int64]) throws -> [FTSChunk] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return try FTSChunk.fetchAll(db, sql: """
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

    /// A BM25-ranked full-text hit: chunk rowid, a relevance score (higher = better),
    /// and a `snippet()` excerpt — the window of text around the matched terms.
    struct Hit: Sendable {
        let chunkId: Int64
        let score: Double
        let snippet: String
    }

    /// BM25 keyword search on chunk text, ordered by relevance.
    /// - Parameter itemIds: when non-nil, restricts the search to chunks of those items.
    func bm25Search(query: String, maxResults: Int = 50, itemIds: [String]? = nil) throws -> [Hit] {
        try dbQueue.read { db in
            let sanitized = Self.sanitizeFTS5Query(query)
            guard !sanitized.isEmpty else { return [] }

            // snippet() returns the text window around the match (column 0 = chunk_text,
            // up to 16 tokens) so the agent sees *why* a chunk matched, not a blind prefix.
            // bm25() is lower (more negative) for better matches; negate so higher = better.
            var sql = """
                SELECT chunks_fts.rowid AS rowid,
                       bm25(chunks_fts) AS score,
                       snippet(chunks_fts, 0, '', '', '…', 16) AS snip
                FROM chunks_fts
                """
            var arguments: [DatabaseValueConvertible] = [sanitized]
            if let itemIds, !itemIds.isEmpty {
                let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
                sql += """
                     JOIN chunks ON chunks.id = chunks_fts.rowid
                    WHERE chunks_fts MATCH ? AND chunks.item_id IN (\(placeholders))
                    """
                arguments += itemIds
            } else {
                sql += " WHERE chunks_fts MATCH ?"
            }
            sql += " ORDER BY rank LIMIT ?"
            arguments.append(maxResults)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map {
                Hit(chunkId: $0["rowid"], score: -($0["score"] as Double), snippet: $0["snip"] ?? "")
            }
        }
    }

    /// Build an FTS5 MATCH expression from a natural-language query.
    /// Each term becomes a quoted prefix, joined by OR — so partial matches surface and
    /// BM25 ranks documents containing more (and rarer) of the terms higher. This is far
    /// more forgiving than ANDing every word, which often returns nothing.
    private static func sanitizeFTS5Query(_ query: String) -> String {
        let words = query.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        // Double any interior quotes — FTS5 string tokens escape `"` as `""`.
        // Without this a query containing a stray quote produces a malformed MATCH
        // expression that throws and silently yields zero results. Trailing `*` makes
        // each term a prefix match.
        return words
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " OR ")
    }
}

// MARK: - FTSChunk Model

struct FTSChunk: Codable, FetchableRecord, MutablePersistableRecord {
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
