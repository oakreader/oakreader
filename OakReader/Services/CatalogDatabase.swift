import Foundation
import GRDB

/// GRDB wrapper: manages the SQLite database at ~/OakReader/library.sqlite.
/// Handles schema creation, migrations, and provides the database queue for all queries.
final class CatalogDatabase {
    let dbQueue: DatabaseQueue

    init() throws {
        try Self.createBaseDirectories()
        let dataDir = Self.dataDirectory

        let dbPath = dataDir.appendingPathComponent("library.sqlite").path

        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try Self.migrator.migrate(dbQueue)
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
