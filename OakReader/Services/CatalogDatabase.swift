import Foundation
import GRDB

/// GRDB wrapper: manages the SQLite database at ~/OakReader/library.sqlite.
/// Handles schema creation, migrations, and provides the database queue for all queries.
final class CatalogDatabase {
    let dbQueue: DatabaseQueue

    /// ~/OakReader/
    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader", isDirectory: true)
    }

    /// ~/OakReader/storage/
    static var storageDirectory: URL {
        dataDirectory.appendingPathComponent("storage", isDirectory: true)
    }

    /// ~/OakReader/logs/
    static var logsDirectory: URL {
        dataDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    init() throws {
        let dataDir = Self.dataDirectory
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.storageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.logsDirectory, withIntermediateDirectories: true)

        let dbPath = dataDir.appendingPathComponent("library.sqlite").path

        // Greenfield: if old schema exists (has "documents" table), delete and recreate
        if FileManager.default.fileExists(atPath: dbPath) {
            Self.deleteIfOldSchema(path: dbPath)
        }

        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// Detect old schema and delete the DB file.
    /// Checks for legacy `documents` table or pre-attachment `items` table (has `file_name` column).
    private static func deleteIfOldSchema(path: String) {
        do {
            var config = Configuration()
            config.foreignKeysEnabled = false
            config.readonly = true
            let tmpQueue = try DatabaseQueue(path: path, configuration: config)
            let isOld = try tmpQueue.read { db in
                if try db.tableExists("documents") { return true }
                // Pre-attachment schema: items table has file_name column but no attachments table
                if try db.tableExists("items") && !db.tableExists("attachments") { return true }
                return false
            }
            if isOld {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + "-wal")
                try? FileManager.default.removeItem(atPath: path + "-shm")
            }
        } catch {
            // If we can't open it, delete it anyway
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-greenfield") { db in
            // Items (bibliographic references)
            try db.create(table: "items") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("storage_key", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "")
                t.column("is_favorite", .integer).notNull().defaults(to: false)
                t.column("last_opened_at", .text)
                t.column("sync_status", .text).notNull().defaults(to: "local")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("is_inbox", .integer).notNull().defaults(to: false)
            }

            // Attachments (files belonging to items)
            try db.create(table: "attachments") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("storage_key", .text).notNull().unique()
                t.column("file_name", .text).notNull()
                t.column("attachment_type", .text).notNull().defaults(to: "pdf")
                t.column("source_url", .text)
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("page_count", .integer).notNull().defaults(to: 0)
                t.column("is_primary", .integer).notNull().defaults(to: true)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_attachments_item_id", on: "attachments", columns: ["item_id"])

            // Collections (with smart collection support)
            try db.create(table: "collections") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "folder")
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("parent_id", .text).references("collections", onDelete: .cascade)
                t.column("is_smart", .integer).notNull().defaults(to: false)
                t.column("is_system", .integer).notNull().defaults(to: false)
                t.column("filter_rules", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Many-to-many: item <-> collection (was: document_collections)
            try db.create(table: "collection_items") { t in
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("collection_id", .text).notNull().references("collections", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.primaryKey(["item_id", "collection_id"])
            }

            // Properties (NEW)
            try db.create(table: "properties") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()       // multi_select, single_select, number, text
                t.column("icon", .text).notNull().defaults(to: "tag")
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("is_system", .integer).notNull().defaults(to: false)
            }

            // Property options (for select-type properties)
            try db.create(table: "property_options") { t in
                t.column("id", .text).primaryKey()
                t.column("property_id", .text).notNull().references("properties", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("color_hex", .text).notNull().defaults(to: "999999")
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_property_options_property_id", on: "property_options", columns: ["property_id"])

            // Item property values (junction: item <-> property, replaces document_tags)
            try db.create(table: "item_property_values") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("property_id", .text).notNull().references("properties", onDelete: .cascade)
                t.column("option_id", .text).references("property_options", onDelete: .cascade)
                t.column("text_value", .text)
            }
            try db.create(index: "idx_item_property_values_item", on: "item_property_values", columns: ["item_id"])
            try db.create(index: "idx_item_property_values_property", on: "item_property_values", columns: ["property_id"])

            // Conversations (was: chat_sessions)
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("item_id", .text).references("items", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("message_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Notes (document_id → item_id)
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("is_pinned", .integer).notNull().defaults(to: false)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_notes_item_id", on: "notes", columns: ["item_id"])

            // Citations (was: reference_metadata)
            try db.create(table: "citations") { t in
                t.column("item_id", .text).primaryKey()
                    .references("items", onDelete: .cascade)
                t.column("csl_json", .text).notNull()
                t.column("csl_type", .text).notNull().defaults(to: "document")
                t.column("doi", .text)
                t.column("year", .integer)
                t.column("container_title", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_citations_doi", on: "citations", columns: ["doi"], ifNotExists: true)
            try db.create(index: "idx_citations_year", on: "citations", columns: ["year"], ifNotExists: true)
            try db.create(index: "idx_citations_type", on: "citations", columns: ["csl_type"], ifNotExists: true)

            // FTS5 full-text search
            try db.create(virtualTable: "items_fts", using: FTS5()) { t in
                t.synchronize(withTable: "items")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("author")
            }

            // MARK: - Seed System Properties

            // Tags property (multi_select)
            let tagsPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Tags', 'multi_select', 'tag', 0, 1)
            """, arguments: [tagsPropertyId])

            let tagOptions: [(name: String, color: String, pos: Int)] = [
                ("Important", "FF6666", 0),
                ("To Read", "2EA8E5", 1),
                ("In Progress", "FF8C19", 2),
                ("Reviewed", "5FB236", 3),
            ]
            for opt in tagOptions {
                try db.execute(sql: """
                    INSERT INTO property_options (id, property_id, name, color_hex, position)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, tagsPropertyId, opt.name, opt.color, opt.pos])
            }

            // Status property (single_select)
            let statusPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Status', 'single_select', 'circle.dotted', 1, 1)
            """, arguments: [statusPropertyId])

            let statusOptions: [(name: String, color: String, pos: Int)] = [
                ("Unread", "999999", 0),
                ("Reading", "2EA8E5", 1),
                ("Completed", "5FB236", 2),
                ("Archived", "A28AE5", 3),
            ]
            for opt in statusOptions {
                try db.execute(sql: """
                    INSERT INTO property_options (id, property_id, name, color_hex, position)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, statusPropertyId, opt.name, opt.color, opt.pos])
            }

            // Rating property (number, no options)
            let ratingPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Rating', 'number', 'star', 2, 1)
            """, arguments: [ratingPropertyId])

            // MARK: - Seed System Smart Collections

            let now = Date().iso8601String
            let systemCollections: [(id: String, name: String, icon: String, order: Int, rules: String)] = [
                (SystemCollectionID.inbox.uuidString, "Inbox", "tray.and.arrow.down", 0,
                 #"{"match":"all","conditions":[{"field":"is_inbox","op":"eq","value":"true"}]}"#),
                (SystemCollectionID.allItems.uuidString, "All Items", "books.vertical", 1,
                 #"{"match":"all","conditions":[]}"#),
                (SystemCollectionID.recent.uuidString, "Recently Added", "clock", 2,
                 #"{"match":"all","conditions":[{"field":"created_at","op":"within_days","value":"7"}]}"#),
                (SystemCollectionID.pdfs.uuidString, "PDFs", "doc.fill", 3,
                 #"{"match":"all","conditions":[{"field":"item_type","op":"eq","value":"pdf"}]}"#),
                (SystemCollectionID.webSnapshots.uuidString, "Web", "globe", 4,
                 #"{"match":"all","conditions":[{"field":"item_type","op":"eq","value":"webSnapshot"}]}"#),
                (SystemCollectionID.videos.uuidString, "Videos", "play.rectangle", 5,
                 #"{"match":"all","conditions":[{"field":"item_type","op":"eq","value":"embed"}]}"#),
            ]
            for sc in systemCollections {
                try db.execute(sql: """
                    INSERT INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, NULL, 1, 1, ?, ?, ?)
                """, arguments: [sc.id, localUserId, sc.name, sc.icon, sc.order, sc.rules, now, now])
            }
        }

        return migrator
    }

    // MARK: - Storage Key Generation

    /// Generate an 8-character random alphanumeric key.
    static func generateStorageKey() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    // MARK: - Item-Level Helpers

    /// Storage directory for a specific item: storage/{itemKey}/
    static func documentDirectory(storageKey: String) -> URL {
        storageDirectory.appendingPathComponent(storageKey, isDirectory: true)
    }

    /// Sessions directory for an item: storage/{itemKey}/sessions/
    static func documentSessionsDirectory(storageKey: String) -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent("sessions", isDirectory: true)
    }

    /// Notes directory for an item: storage/{itemKey}/notes/
    static func documentNotesDirectory(storageKey: String) -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent("notes", isDirectory: true)
    }

    /// Notes attachments directory for an item: storage/{itemKey}/notes/attachments/
    static func documentNotesAttachmentsDirectory(storageKey: String) -> URL {
        documentNotesDirectory(storageKey: storageKey).appendingPathComponent("attachments", isDirectory: true)
    }

    // MARK: - Attachment-Level Helpers

    /// Attachment directory: storage/{itemKey}/files/{attachmentKey}/
    static func attachmentDirectory(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        documentDirectory(storageKey: itemStorageKey)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(attachmentStorageKey, isDirectory: true)
    }

    /// Attachment file URL: storage/{itemKey}/files/{attachmentKey}/{fileName}
    static func attachmentFileURL(itemStorageKey: String, attachmentStorageKey: String, fileName: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent(fileName)
    }

    /// Cover image URL for an attachment: storage/{itemKey}/files/{attachmentKey}/cover.webp
    static func attachmentCoverURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("cover.webp")
    }

    /// Metadata JSON URL for an embed attachment.
    static func attachmentMetadataURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("metadata.json")
    }

    /// Transcript file URL for an embed attachment.
    static func attachmentTranscriptURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("transcript.txt")
    }
}

// MARK: - ISO 8601 Date Helpers

extension Date {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var iso8601String: String {
        Self.iso8601Formatter.string(from: self)
    }

    init?(iso8601String: String) {
        guard let date = Self.iso8601Formatter.date(from: iso8601String) else { return nil }
        self = date
    }
}
