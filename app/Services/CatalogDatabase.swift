import Foundation

/// Where the library lives on disk.
///
/// This was the GRDB wrapper: schema, migrations, seeding and the queue every
/// query ran through. All four moved to the core, which is the one process that
/// owns the schema now. What a shell still needs is the layout — which
/// directory holds the database, where a document's files go — and that is
/// filesystem knowledge, not catalog knowledge.
final class CatalogDatabase {
    init() throws {
        try Self.createBaseDirectories()

        // Reclaim the chunk/FTS5 index left by older builds. The app no longer
        // indexes document content — chat grounds on the open document and the
        // `oak` CLI reads items directly — so search.sqlite is dead weight (it
        // reached hundreds of MB on large libraries). Best-effort; never blocks
        // opening the catalog.
        Self.removeLegacySearchIndex()
    }

    /// Deletes the regenerable full-text chunk index (and its WAL/SHM siblings)
    /// written by builds that shipped the FTS5 content index.
    private static func removeLegacySearchIndex() {
        let dir = Self.dataDirectory
        for name in ["search.sqlite", "search.sqlite-wal", "search.sqlite-shm"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
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
