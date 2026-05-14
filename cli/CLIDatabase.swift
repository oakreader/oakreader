import Foundation
import GRDB

// MARK: - Lightweight Record Types (CLI-only, duplicated from app)

struct CLIItem: Codable, FetchableRecord {
    var id: String
    var title: String
    var author: String
    var citeKey: String?
    var storageKey: String
    var createdAt: String
    var updatedAt: String
    var lastOpenedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, author
        case citeKey = "cite_key"
        case storageKey = "storage_key"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastOpenedAt = "last_opened_at"
    }
}

struct CLIAttachment: Codable, FetchableRecord {
    var id: String
    var itemId: String
    var fileName: String
    var attachmentType: String
    var sourceURL: String?
    var fileSize: Int64
    var pageCount: Int
    var isPrimary: Bool
    var storageKey: String

    enum CodingKeys: String, CodingKey {
        case id
        case itemId = "item_id"
        case fileName = "file_name"
        case attachmentType = "attachment_type"
        case sourceURL = "source_url"
        case fileSize = "file_size"
        case pageCount = "page_count"
        case isPrimary = "is_primary"
        case storageKey = "storage_key"
    }
}

struct CLICollection: Codable, FetchableRecord {
    var id: String
    var name: String
    var icon: String
    var sortOrder: Int
    var parentId: String?
    var isSmart: Bool
    var isSystem: Bool
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case sortOrder = "sort_order"
        case parentId = "parent_id"
        case isSmart = "is_smart"
        case isSystem = "is_system"
        case createdAt = "created_at"
    }
}

struct CLIPropertyOption: Codable, FetchableRecord {
    var id: String
    var propertyId: String
    var name: String
    var colorHex: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case id
        case propertyId = "property_id"
        case name
        case colorHex = "color_hex"
        case position
    }
}

// MARK: - System Collection IDs

enum CLISystemCollectionID {
    static let allItems    = "00000000-0000-0000-0000-000000000002"
    static let pdfs        = "00000000-0000-0000-0000-000000000005"
    static let webSnapshots = "00000000-0000-0000-0000-000000000006"
    static let videos      = "00000000-0000-0000-0000-000000000007"
    static let recentlyRead = "00000000-0000-0000-0000-000000000008"
    static let notes       = "00000000-0000-0000-0000-000000000009"
    static let duplicates  = "00000000-0000-0000-0000-00000000000A"

    static let all: Set<String> = [allItems, pdfs, webSnapshots, videos, recentlyRead, notes, duplicates]
}

// MARK: - Database Connection

final class CLIDatabase {
    let dbQueue: DatabaseQueue
    private let userId = "local"

    init(path: String? = nil) throws {
        let dbPath = path ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent("OakReader/library.sqlite").path
        }()

        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw CLIDatabaseError.databaseNotFound(dbPath)
        }

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.readonly = false
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
    }

    // MARK: - Date Helpers

    private func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: - Items

    func fetchAllItems(
        collectionName: String? = nil,
        tagName: String? = nil,
        type: String? = nil,
        search: String? = nil,
        sort: String? = nil,
        limit: Int? = nil
    ) throws -> [(item: CLIItem, attachments: [CLIAttachment])] {
        try dbQueue.read { db in
            var sql = "SELECT DISTINCT i.* FROM items i"
            var args: [DatabaseValueConvertible] = []
            var joins: [String] = []
            var conditions: [String] = []

            if collectionName != nil {
                joins.append("""
                    JOIN collection_items ci ON ci.item_id = i.id
                    JOIN collections c ON c.id = ci.collection_id
                """)
            }

            if tagName != nil {
                joins.append("""
                    JOIN item_property_values ipv ON ipv.item_id = i.id
                    JOIN property_options po ON po.id = ipv.option_id
                    JOIN properties p ON p.id = ipv.property_id AND p.name = 'Tags'
                """)
            }

            if type != nil {
                joins.append("JOIN attachments a_type ON a_type.item_id = i.id AND a_type.is_primary = 1")
            }

            sql += " " + joins.joined(separator: " ")

            if let collectionName {
                conditions.append("LOWER(c.name) = LOWER(?)")
                args.append(collectionName)
            }

            if let tagName {
                conditions.append("LOWER(po.name) = LOWER(?)")
                args.append(tagName)
            }

            if let type {
                let mapped = Self.mapItemType(type)
                conditions.append("a_type.attachment_type = ?")
                args.append(mapped)
            }

            if let search {
                conditions.append("i.rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)")
                // FTS5: tokenize each word as a prefix match
                let terms = search.split(separator: " ").map { term -> String in
                    let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(escaped)\"*"
                }
                args.append(terms.joined(separator: " "))
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }

            switch sort?.lowercased() {
            case "title":
                sql += " ORDER BY LOWER(i.title) ASC"
            case "author":
                sql += " ORDER BY LOWER(i.author) ASC, LOWER(i.title) ASC"
            case "date":
                sql += " ORDER BY i.created_at DESC"
            default:
                sql += " ORDER BY i.created_at DESC"
            }

            if let limit {
                sql += " LIMIT ?"
                args.append(limit)
            }

            let items = try CLIItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            return try items.map { item in
                let attachments = try CLIAttachment.fetchAll(
                    db,
                    sql: "SELECT * FROM attachments WHERE item_id = ? ORDER BY is_primary DESC",
                    arguments: [item.id]
                )
                return (item: item, attachments: attachments)
            }
        }
    }

    func fetchItem(id: String) throws -> (item: CLIItem, attachments: [CLIAttachment])? {
        try dbQueue.read { db in
            guard let item = try CLIItem.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id]) else {
                return nil
            }
            let attachments = try CLIAttachment.fetchAll(
                db,
                sql: "SELECT * FROM attachments WHERE item_id = ? ORDER BY is_primary DESC",
                arguments: [id]
            )
            return (item: item, attachments: attachments)
        }
    }

    func fetchItemTags(itemId: String) throws -> [CLIPropertyOption] {
        try dbQueue.read { db in
            try CLIPropertyOption.fetchAll(db, sql: """
                SELECT po.* FROM property_options po
                JOIN item_property_values ipv ON ipv.option_id = po.id
                JOIN properties p ON p.id = ipv.property_id AND p.name = 'Tags'
                WHERE ipv.item_id = ?
                ORDER BY po.position
            """, arguments: [itemId])
        }
    }

    func fetchItemStatus(itemId: String) throws -> CLIPropertyOption? {
        try dbQueue.read { db in
            try CLIPropertyOption.fetchOne(db, sql: """
                SELECT po.* FROM property_options po
                JOIN item_property_values ipv ON ipv.option_id = po.id
                JOIN properties p ON p.id = ipv.property_id AND p.name = 'Status'
                WHERE ipv.item_id = ?
            """, arguments: [itemId])
        }
    }

    func fetchItemCollections(itemId: String) throws -> [CLICollection] {
        try dbQueue.read { db in
            try CLICollection.fetchAll(db, sql: """
                SELECT c.* FROM collections c
                JOIN collection_items ci ON ci.collection_id = c.id
                WHERE ci.item_id = ? AND c.is_system = 0
                ORDER BY c.name
            """, arguments: [itemId])
        }
    }

    // MARK: - Collections

    func fetchAllCollections() throws -> [CLICollection] {
        try dbQueue.read { db in
            try CLICollection.fetchAll(db, sql: """
                SELECT * FROM collections WHERE is_smart = 0 AND is_system = 0
                ORDER BY sort_order, LOWER(name)
            """)
        }
    }

    func fetchCollectionItemCount(collectionId: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_items WHERE collection_id = ?",
                             arguments: [collectionId]) ?? 0
        }
    }

    func createCollection(name: String, parentId: String?) throws -> String {
        let id = UUID().uuidString
        let timestamp = now()
        let maxOrder = try dbQueue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), 0) FROM collections WHERE is_system = 0") ?? 0
        }

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, created_at, updated_at)
                VALUES (?, ?, ?, 'folder', ?, ?, 0, 0, ?, ?)
            """, arguments: [id, self.userId, name, maxOrder + 1, parentId, timestamp, timestamp])
        }
        return id
    }

    func renameCollection(id: String, newName: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE collections SET name = ?, updated_at = ? WHERE id = ?",
                           arguments: [newName, self.now(), id])
        }
    }

    func deleteCollection(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [id])
        }
    }

    func addItemToCollection(collectionId: String, itemId: String) throws {
        let timestamp = now()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO collection_items (item_id, collection_id, created_at)
                VALUES (?, ?, ?)
            """, arguments: [itemId, collectionId, timestamp])
        }
    }

    func removeItemFromCollection(collectionId: String, itemId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM collection_items WHERE item_id = ? AND collection_id = ?",
                           arguments: [itemId, collectionId])
        }
    }

    // MARK: - Tags (property_options under the "Tags" property)

    func fetchTagsPropertyId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM properties WHERE name = 'Tags' AND type = 'multi_select'")
        }
    }

    func fetchAllTags() throws -> [(tag: CLIPropertyOption, count: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT po.*, COUNT(ipv.id) AS item_count
                FROM property_options po
                JOIN properties p ON p.id = po.property_id AND p.name = 'Tags'
                LEFT JOIN item_property_values ipv ON ipv.option_id = po.id
                GROUP BY po.id
                ORDER BY po.position
            """)
            return rows.map { row in
                let tag = CLIPropertyOption(
                    id: row["id"],
                    propertyId: row["property_id"],
                    name: row["name"],
                    colorHex: row["color_hex"],
                    position: row["position"]
                )
                let count: Int = row["item_count"]
                return (tag: tag, count: count)
            }
        }
    }

    func createTag(name: String, colorHex: String?) throws -> String {
        guard let propertyId = try fetchTagsPropertyId() else {
            throw CLIDatabaseError.tagsPropertyNotFound
        }

        let id = UUID().uuidString
        let maxPosition = try dbQueue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) FROM property_options WHERE property_id = ?",
                             arguments: [propertyId]) ?? -1
        }

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO property_options (id, property_id, name, color_hex, position)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [id, propertyId, name, colorHex ?? "999999", maxPosition + 1])
        }
        return id
    }

    func renameTag(id: String, newName: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE property_options SET name = ? WHERE id = ?",
                           arguments: [newName, id])
        }
    }

    func deleteTag(id: String) throws {
        try dbQueue.write { db in
            // Remove all item_property_values referencing this option first (cascade should handle but be explicit)
            try db.execute(sql: "DELETE FROM item_property_values WHERE option_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM property_options WHERE id = ?", arguments: [id])
        }
    }

    func addTagToItem(tagId: String, itemId: String) throws {
        guard let propertyId = try fetchTagsPropertyId() else {
            throw CLIDatabaseError.tagsPropertyNotFound
        }
        let id = UUID().uuidString
        try dbQueue.write { db in
            // Check if already tagged
            let existing = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM item_property_values
                WHERE item_id = ? AND property_id = ? AND option_id = ?
            """, arguments: [itemId, propertyId, tagId]) ?? 0
            guard existing == 0 else { return }

            try db.execute(sql: """
                INSERT INTO item_property_values (id, item_id, property_id, option_id)
                VALUES (?, ?, ?, ?)
            """, arguments: [id, itemId, propertyId, tagId])
        }
    }

    func removeTagFromItem(tagId: String, itemId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM item_property_values WHERE item_id = ? AND option_id = ?",
                           arguments: [itemId, tagId])
        }
    }

    // MARK: - Status (property_options under the "Status" property)

    func fetchStatusPropertyId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM properties WHERE name = 'Status' AND type = 'single_select'")
        }
    }

    func fetchAllStatuses() throws -> [CLIPropertyOption] {
        try dbQueue.read { db in
            try CLIPropertyOption.fetchAll(db, sql: """
                SELECT po.* FROM property_options po
                JOIN properties p ON p.id = po.property_id AND p.name = 'Status'
                ORDER BY po.position
            """)
        }
    }

    func setItemStatus(itemId: String, statusOptionId: String) throws {
        guard let propertyId = try fetchStatusPropertyId() else {
            throw CLIDatabaseError.statusPropertyNotFound
        }
        try dbQueue.write { db in
            // Remove existing status value
            try db.execute(sql: "DELETE FROM item_property_values WHERE item_id = ? AND property_id = ?",
                           arguments: [itemId, propertyId])
            // Insert new
            let id = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO item_property_values (id, item_id, property_id, option_id)
                VALUES (?, ?, ?, ?)
            """, arguments: [id, itemId, propertyId, statusOptionId])
        }
    }

    // MARK: - Stats

    func fetchStats() throws -> (items: Int, collections: Int, tags: Int) {
        try dbQueue.read { db in
            let items = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0
            let collections = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collections WHERE is_smart = 0 AND is_system = 0") ?? 0
            let tags = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM property_options po
                JOIN properties p ON p.id = po.property_id AND p.name = 'Tags'
            """) ?? 0
            return (items: items, collections: collections, tags: tags)
        }
    }

    // MARK: - Import (Insert)

    struct InsertItemInput {
        let id: String
        let storageKey: String
        let title: String
        let author: String
        let attachmentId: String
        let attachmentStorageKey: String
        let fileName: String
        let attachmentType: String
        let sourceURL: String?
        let fileSize: Int64
        let pageCount: Int
    }

    /// Insert an item and its primary attachment in one transaction.
    func insertItem(_ input: InsertItemInput) throws {
        let timestamp = now()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO items (id, user_id, storage_key, title, author, sync_status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'local', ?, ?)
            """, arguments: [input.id, self.userId, input.storageKey, input.title, input.author, timestamp, timestamp])

            try db.execute(sql: """
                INSERT INTO attachments (id, item_id, storage_key, file_name, attachment_type, source_url, file_size, page_count, is_primary, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            """, arguments: [input.attachmentId, input.id, input.attachmentStorageKey, input.fileName, input.attachmentType, input.sourceURL, input.fileSize, input.pageCount, timestamp, timestamp])
        }
    }

    /// Return storage paths for all primary attachments (for hash-based duplicate detection).
    func findAttachmentPaths() throws -> [(itemStorageKey: String, attachmentStorageKey: String, fileName: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.storage_key AS item_storage_key,
                       a.storage_key AS att_storage_key,
                       a.file_name
                FROM attachments a
                JOIN items i ON i.id = a.item_id
                WHERE a.is_primary = 1
            """)
            return rows.map { row in
                (
                    itemStorageKey: row["item_storage_key"] as String,
                    attachmentStorageKey: row["att_storage_key"] as String,
                    fileName: row["file_name"] as String
                )
            }
        }
    }

    // MARK: - Search

    struct SearchResultRow {
        let itemId: String
        let title: String
        let author: String
        let citeKey: String?
        let attachmentType: String?
        let pageCount: Int?
        let year: Int?
        let doi: String?
        let journal: String?
        let abstract: String?
        let tags: String?
    }

    /// Keyword search using FTS5 + abstract/DOI/journal/tag LIKE queries (mirrors SearchLibraryTool).
    func keywordSearch(query: String, limit: Int = 20) throws -> [SearchResultRow] {
        try dbQueue.read { db in
            let words = query.lowercased()
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard !words.isEmpty else { return [] }

            var matchingIds = Set<String>()

            // FTS5 on title + author
            let ftsTokens = words.compactMap { word -> String? in
                let clean = word.filter { $0.isLetter || $0.isNumber }
                return clean.isEmpty ? nil : "\"\(clean)\""
            }
            if !ftsTokens.isEmpty {
                let ftsQuery = ftsTokens.joined(separator: " ")
                for row in try Row.fetchAll(db, sql: """
                    SELECT i.id FROM items i
                    JOIN items_fts ON items_fts.rowid = i.rowid
                    WHERE items_fts MATCH ?
                    """, arguments: [ftsQuery]) {
                    matchingIds.insert(row["id"] as String)
                }
            }

            // Abstract LIKE
            if words.count <= 5 {
                let absConditions = words.map { _ in "c.abstract LIKE ?" }.joined(separator: " AND ")
                let absArgs = words.map { "%\($0)%" }
                for row in try Row.fetchAll(db, sql: """
                    SELECT c.item_id FROM citations c
                    WHERE c.abstract IS NOT NULL AND (\(absConditions))
                    """, arguments: StatementArguments(absArgs)) {
                    matchingIds.insert(row["item_id"] as String)
                }
            }

            // DOI
            let fullPattern = "%\(query)%"
            for row in try Row.fetchAll(db, sql: "SELECT item_id FROM citations WHERE doi LIKE ?",
                                        arguments: [fullPattern]) {
                matchingIds.insert(row["item_id"] as String)
            }

            // Journal
            for row in try Row.fetchAll(db, sql: "SELECT item_id FROM citations WHERE container_title LIKE ?",
                                        arguments: [fullPattern]) {
                matchingIds.insert(row["item_id"] as String)
            }

            // Tags
            let tagConditions = words.map { _ in "po.name LIKE ?" }.joined(separator: " OR ")
            let tagArgs = words.map { "%\($0)%" }
            for row in try Row.fetchAll(db, sql: """
                SELECT DISTINCT ipv.item_id FROM item_property_values ipv
                JOIN property_options po ON po.id = ipv.option_id
                WHERE \(tagConditions)
                """, arguments: StatementArguments(tagArgs)) {
                matchingIds.insert(row["item_id"] as String)
            }

            guard !matchingIds.isEmpty else { return [] }
            return try Self.fetchSearchDetails(db: db, ids: Array(matchingIds), limit: limit)
        }
    }

    /// Fetch enriched details for a set of item IDs (shared by keyword and semantic search).
    static func fetchSearchDetails(db: Database, ids: [String], limit: Int) throws -> [SearchResultRow] {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.id, i.title, i.author, i.cite_key,
                   a.attachment_type, a.page_count,
                   c.year, c.doi, c.container_title, c.abstract,
                   (SELECT GROUP_CONCAT(po.name, ', ')
                    FROM item_property_values ipv
                    JOIN property_options po ON po.id = ipv.option_id
                    JOIN properties p ON p.id = ipv.property_id AND p.name = 'Tags'
                    WHERE ipv.item_id = i.id) AS tag_names
            FROM items i
            LEFT JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
            LEFT JOIN citations c ON c.item_id = i.id
            WHERE i.id IN (\(placeholders))
            ORDER BY
                CASE WHEN i.last_opened_at IS NOT NULL THEN 0 ELSE 1 END,
                i.last_opened_at DESC,
                i.created_at DESC
            LIMIT ?
            """, arguments: StatementArguments(ids + ["\(limit)"]))

        return rows.map { row in
            SearchResultRow(
                itemId: row["id"],
                title: row["title"],
                author: row["author"],
                citeKey: row["cite_key"],
                attachmentType: row["attachment_type"],
                pageCount: row["page_count"],
                year: row["year"],
                doi: row["doi"],
                journal: row["container_title"],
                abstract: row["abstract"],
                tags: row["tag_names"]
            )
        }
    }

    /// Fetch indexed item IDs from the separate semantic.db.
    func fetchSemanticChunkItemIds() throws -> Set<String> {
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader", isDirectory: true)
        let semanticDBURL = dataDir.appendingPathComponent("semantic.db")
        guard FileManager.default.fileExists(atPath: semanticDBURL.path) else { return [] }
        let semanticQueue = try DatabaseQueue(path: semanticDBURL.path)
        return try semanticQueue.read { db in
            guard try db.tableExists("chunks") else { return [] }
            let ids = try String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM chunks")
            return Set(ids)
        }
    }

    // MARK: - Helpers

    static func mapItemType(_ input: String) -> String {
        switch input.lowercased() {
        case "pdf": return "pdf"
        case "web", "websnapshot": return "webSnapshot"
        case "video", "embed": return "embed"
        case "note", "markdown": return "markdown"
        default: return input
        }
    }
}

// MARK: - Errors

enum CLIDatabaseError: LocalizedError {
    case databaseNotFound(String)
    case tagsPropertyNotFound
    case statusPropertyNotFound

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return "Database not found at \(path). Is OakReader installed and has been launched at least once?"
        case .tagsPropertyNotFound:
            return "Tags property not found in database. The database may be corrupted."
        case .statusPropertyNotFound:
            return "Status property not found in database. The database may be corrupted."
        }
    }
}
