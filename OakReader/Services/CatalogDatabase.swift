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
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-create-tables") { db in
            // Documents
            try db.create(table: "documents") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("storage_key", .text).notNull().unique()
                t.column("original_file_name", .text).notNull()
                t.column("title", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "")
                t.column("page_count", .integer).notNull().defaults(to: 0)
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("is_favorite", .integer).notNull().defaults(to: false)
                t.column("date_last_opened", .text)
                t.column("sync_status", .text).notNull().defaults(to: "local")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Collections (hierarchical)
            try db.create(table: "collections") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "folder")
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("parent_id", .text).references("collections", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Tags
            try db.create(table: "tags") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("color_hex", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Many-to-many: document <-> collection
            try db.create(table: "document_collections") { t in
                t.column("document_id", .text).notNull().references("documents", onDelete: .cascade)
                t.column("collection_id", .text).notNull().references("collections", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.primaryKey(["document_id", "collection_id"])
            }

            // Many-to-many: document <-> tag
            try db.create(table: "document_tags") { t in
                t.column("document_id", .text).notNull().references("documents", onDelete: .cascade)
                t.column("tag_id", .text).notNull().references("tags", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.primaryKey(["document_id", "tag_id"])
            }

            // Chat sessions metadata
            try db.create(table: "chat_sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("document_id", .text).notNull().references("documents", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("message_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // FTS5 full-text search (local-only, not synced)
            try db.create(virtualTable: "documents_fts", using: FTS5()) { t in
                t.synchronize(withTable: "documents")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("author")
                t.column("original_file_name")
            }
        }

        migrator.registerMigration("v2-document-type") { db in
            try db.alter(table: "documents") { t in
                t.add(column: "document_type", .text).notNull().defaults(to: "pdf")
                t.add(column: "source_url", .text)
            }
        }

        migrator.registerMigration("v3-inbox-flag") { db in
            try db.alter(table: "documents") { t in
                t.add(column: "is_in_inbox", .integer).notNull().defaults(to: 0)
            }
            // Backfill: items imported from the Chrome extension have a source_url
            try db.execute(sql: "UPDATE documents SET is_in_inbox = 1 WHERE source_url IS NOT NULL")
        }

        migrator.registerMigration("v4-notes") { db in
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("document_id", .text).notNull().references("documents", onDelete: .cascade)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("is_pinned", .integer).notNull().defaults(to: false)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_notes_document_id", on: "notes", columns: ["document_id"])
        }

        migrator.registerMigration("v5-reference-metadata") { db in
            try db.create(table: "reference_metadata") { t in
                t.column("document_id", .text).primaryKey()
                    .references("documents", onDelete: .cascade)
                t.column("csl_json", .text).notNull()
                t.column("csl_type", .text).notNull().defaults(to: "document")
                t.column("doi", .text)
                t.column("year", .integer)
                t.column("container_title", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(
                index: "idx_ref_meta_doi",
                on: "reference_metadata",
                columns: ["doi"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_ref_meta_year",
                on: "reference_metadata",
                columns: ["year"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_ref_meta_type",
                on: "reference_metadata",
                columns: ["csl_type"],
                ifNotExists: true
            )
        }

        return migrator
    }

    // MARK: - Storage Key Generation

    /// Generate an 8-character random alphanumeric key.
    static func generateStorageKey() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    // MARK: - Helpers

    /// Storage directory for a specific document.
    static func documentDirectory(storageKey: String) -> URL {
        storageDirectory.appendingPathComponent(storageKey, isDirectory: true)
    }

    /// PDF file URL for a document.
    static func documentPDFURL(storageKey: String, fileName: String = "document.pdf") -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent(fileName)
    }

    /// HTML file URL for a web snapshot document.
    static func documentHTMLURL(storageKey: String, fileName: String = "snapshot.html") -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent(fileName)
    }

    /// Cover image URL for a document.
    static func documentCoverURL(storageKey: String) -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent("cover.webp")
    }

    /// Metadata JSON URL for an embed document.
    static func documentMetadataURL(storageKey: String) -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent("metadata.json")
    }

    /// Transcript file URL for an embed document.
    static func documentTranscriptURL(storageKey: String) -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent("transcript.txt")
    }

    /// Sessions directory for a document.
    static func documentSessionsDirectory(storageKey: String) -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent("sessions", isDirectory: true)
    }

    /// Notes directory for a document.
    static func documentNotesDirectory(storageKey: String) -> URL {
        documentDirectory(storageKey: storageKey).appendingPathComponent("notes", isDirectory: true)
    }

    /// Notes attachments directory for a document.
    static func documentNotesAttachmentsDirectory(storageKey: String) -> URL {
        documentNotesDirectory(storageKey: storageKey).appendingPathComponent("attachments", isDirectory: true)
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
