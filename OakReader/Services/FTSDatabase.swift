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
            // Register the CJK-aware tokenizer on every connection so both indexing
            // and querying (and the eraseDatabaseOnSchemaChange reference schema) can
            // resolve `tokenize = 'cjk_bigram'`.
            db.add(tokenizer: CJKBigramTokenizer.self)
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
                t.tokenizer = CJKBigramTokenizer.tokenizerDescriptor()
                t.column("chunk_text")
            }
        }

        // Tracks every item we've *attempted* to index, including ones that yield
        // zero chunks (image-only PDFs, links/HTML with no extractable text). Without
        // this, an empty item never appears in `chunks`, so it can never be counted as
        // "done" and the indexer both retries it every launch and shows a perpetual
        // "Indexing… N remaining" in settings. A row here means "processed — skip it".
        migrator.registerMigration("v2-indexed-items") { db in
            try db.create(table: "indexed_items") { t in
                t.column("item_id", .text).primaryKey()
                t.column("chunk_count", .integer).notNull()
                t.column("indexed_at", .text).notNull()
            }
            // Backfill from already-indexed chunks so existing libraries don't trigger
            // a full re-index — only the genuinely-empty items remain unprocessed.
            try db.execute(sql: """
                INSERT OR IGNORE INTO indexed_items (item_id, chunk_count, indexed_at)
                SELECT item_id, COUNT(*), MIN(created_at) FROM chunks GROUP BY item_id
                """)
        }

        // Records whether we've already run OCR on an empty (0-chunk) item, so a
        // genuinely-blank scanned PDF isn't re-OCR'd (expensive) on every launch.
        migrator.registerMigration("v3-ocr-attempted") { db in
            try db.alter(table: "indexed_items") { t in
                t.add(column: "ocr_attempted", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }

    // MARK: - Destroy All

    /// Delete all chunks for a full rebuild (e.g. from the Rebuild Index button).
    func destroyAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chunks")
            try db.execute(sql: "DELETE FROM indexed_items")
        }
    }

    // MARK: - Chunk Operations

    /// Store an item's chunks and mark it processed, atomically. Deletes any existing
    /// chunks for the item first, so a re-run (forced re-index, crash recovery) is
    /// idempotent. `records` may be empty — the item is still marked (0 chunks) so it
    /// counts as processed and is never retried.
    func storeChunks(_ records: [FTSChunk], itemId: String, indexedAt: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chunks WHERE item_id = ?", arguments: [itemId])
            for var chunk in records {
                try chunk.insert(db)
            }
            try db.execute(sql: """
                INSERT INTO indexed_items (item_id, chunk_count, indexed_at) VALUES (?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET
                    chunk_count = excluded.chunk_count,
                    indexed_at = excluded.indexed_at
                """, arguments: [itemId, records.count, indexedAt])
        }
    }

    /// Delete all chunks for an item and clear its processed marker, so it will be
    /// re-indexed on the next pass.
    func deleteChunks(forItemId itemId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chunks WHERE item_id = ?", arguments: [itemId])
            try db.execute(sql: "DELETE FROM indexed_items WHERE item_id = ?", arguments: [itemId])
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

    /// Whether an item has already been processed (has a marker row), regardless of
    /// whether it produced any chunks.
    func isProcessed(itemId: String) throws -> Bool {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM indexed_items WHERE item_id = ? LIMIT 1", arguments: [itemId]) != nil
        }
    }

    /// Fetch the chunks covering a 0-based page of an item, ordered by rowid. Used to
    /// inject the open document's current page as citable `?c=` passages (PDF, where
    /// page_start == page_end == page index). Section chunks (NULL page) are excluded.
    func fetchChunks(forItemId itemId: String, page: Int) throws -> [FTSChunk] {
        try dbQueue.read { db in
            try FTSChunk.fetchAll(db, sql: """
                SELECT * FROM chunks
                WHERE item_id = ? AND page_start <= ? AND page_end >= ?
                ORDER BY id
                """, arguments: [itemId, page, page])
        }
    }

    /// All chunks of an item, ordered by rowid, capped at `limit`. Used to inject a
    /// non-paginated document (HTML / markdown / web) as citable `?c=` passages — the
    /// whole body is one "page", so there is no page filter. Caller truncates by the
    /// model-window char budget.
    func fetchAllChunks(forItemId itemId: String, limit: Int) throws -> [FTSChunk] {
        try dbQueue.read { db in
            try FTSChunk.fetchAll(db, sql: """
                SELECT * FROM chunks WHERE item_id = ? ORDER BY id LIMIT ?
                """, arguments: [itemId, limit])
        }
    }

    /// All item IDs we've attempted to index (processed set), including empty ones.
    /// Used to skip both already-indexed and known-empty items on the background pass.
    func processedItemIds() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT item_id FROM indexed_items"))
        }
    }

    /// Items that produced no text and haven't been OCR'd yet — candidates for the
    /// OCR backfill pass (filtered to PDFs by the caller against the catalog).
    func ocrPendingItemIds() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT item_id FROM indexed_items WHERE chunk_count = 0 AND ocr_attempted = 0
                """))
        }
    }

    /// Mark an item as OCR'd so it isn't reprocessed even if it yielded no text.
    func markOCRAttempted(itemId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE indexed_items SET ocr_attempted = 1 WHERE item_id = ?", arguments: [itemId])
        }
    }

    // MARK: - Index Stats

    struct IndexStats {
        /// Items that produced at least one chunk (genuinely searchable).
        let indexedItemCount: Int
        /// Items we've attempted, including empty/skipped ones. Reaches the library
        /// total once the background pass finishes, so the UI can stop the spinner.
        let processedItemCount: Int
        let totalChunkCount: Int
    }

    func indexStats() throws -> IndexStats {
        try dbQueue.read { db in
            let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT item_id) FROM chunks") ?? 0
            let processed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_items") ?? 0
            let chunkCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
            return IndexStats(indexedItemCount: itemCount, processedItemCount: processed, totalChunkCount: chunkCount)
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
