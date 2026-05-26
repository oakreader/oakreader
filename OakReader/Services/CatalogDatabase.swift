import Foundation
import GRDB

/// GRDB wrapper: manages the SQLite database at ~/OakReader/library.sqlite.
/// Handles schema creation, migrations, and provides the database queue for all queries.
final class CatalogDatabase {
    let dbQueue: DatabaseQueue

    init() throws {
        // Tier 2 — Bootstrap: ensure filesystem directories exist
        try Self.createBaseDirectories()

        let dbPath = Self.dataDirectory.appendingPathComponent("library.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)

        // Tier 1 — Schema: run DDL migrations
        try Self.migrator.migrate(dbQueue)

        // Tier 3 — Seeding: ensure system rows exist
        try Self.ensureSystemData(dbQueue)
    }

    /// Idempotently seeds system collections, properties, and status options.
    static func ensureSystemData(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            let now = Date().iso8601String

            // ── System Collections ──
            // swiftlint:disable:next large_tuple
            let systemCollections: [(id: String, name: String, icon: String, order: Int, rules: String?)] = [
                (SystemCollectionID.readingList.uuidString, "Reading List", "bookmark", -1, nil),
                (SystemCollectionID.allItems.uuidString, "All Items", "books.vertical", 0,
                 #"{"match":"all","conditions":[]}"#),
                (SystemCollectionID.recentlyRead.uuidString, "Recently Read", "book", 1,
                 #"{"match":"all","conditions":[{"field":"last_opened_at","op":"within_days","value":"14"}]}"#),
                (SystemCollectionID.pdfs.uuidString, "PDFs", "doc.fill", 2,
                 #"{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"pdf"}]}"#),
                (SystemCollectionID.html.uuidString, "Web", "globe", 3,
                 #"{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"html"}]}"#),
                (SystemCollectionID.embeds.uuidString, "Embeds", "link", 4,
                 #"{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"embed"}]}"#),
                (SystemCollectionID.duplicates.uuidString, "Duplicates", "square.on.square", 5, nil),
                (SystemCollectionID.quizCards.uuidString, "Quiz Cards", "rectangle.on.rectangle.angled", 6, nil),
                (SystemCollectionID.bin.uuidString, "Bin", "trash", 7, nil),
            ]
            for sc in systemCollections {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO collections
                        (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, NULL, 1, 1, ?, ?, ?)
                    """,
                    arguments: [sc.id, localUserId, sc.name, sc.icon, sc.order, sc.rules, now, now]
                )
            }

            // ── System Properties ──
            let systemProperties: [(id: String, name: String, type: String, icon: String, position: Int)] = [
                (SystemPropertyID.tags.uuidString, "Tags", "multi_select", "tag", 0),
                (SystemPropertyID.status.uuidString, "Status", "single_select", "circle.dotted", 1),
                (SystemPropertyID.rating.uuidString, "Rating", "number", "star", 2),
            ]
            for prop in systemProperties {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO properties (id, name, type, icon, position, is_system)
                        VALUES (?, ?, ?, ?, ?, 1)
                    """,
                    arguments: [prop.id, prop.name, prop.type, prop.icon, prop.position]
                )
            }

            // ── Status Options ──
            let statusOptions: [(id: String, name: String, color: String, position: Int)] = [
                (SystemStatusOptionID.toRead.uuidString, "To Read", "2EA8E5", 0),
                (SystemStatusOptionID.reading.uuidString, "Reading", "FF8C19", 1),
                (SystemStatusOptionID.finished.uuidString, "Finished", "5FB236", 2),
            ]
            for opt in statusOptions {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO property_options (id, property_id, name, color_hex, position)
                        VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [opt.id, SystemPropertyID.status.uuidString, opt.name, opt.color, opt.position]
                )
            }
        }
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
