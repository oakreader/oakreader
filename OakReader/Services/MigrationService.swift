import Foundation
import PDFKit
import SQLite3

/// One-time migration from the old SwiftData storage to the new GRDB + filesystem model.
/// Reads old SwiftData SQLite, copies PDFs into managed storage, and inserts rows into the new DB.
final class MigrationService {
    private let store: LibraryStore
    private let coverService: LibraryCoverService

    private static let migrationDoneKey = "oakreader.migration.v1.done"

    init(store: LibraryStore, coverService: LibraryCoverService) {
        self.store = store
        self.coverService = coverService
    }

    /// Returns true if migration has already been performed.
    static var isMigrationDone: Bool {
        UserDefaults.standard.bool(forKey: migrationDoneKey)
    }

    /// Run migration if needed. Returns the number of items migrated.
    @discardableResult
    func migrateIfNeeded() -> Int {
        guard !Self.isMigrationDone else { return 0 }
        defer { UserDefaults.standard.set(true, forKey: Self.migrationDoneKey) }

        // Find old SwiftData SQLite file
        guard let oldDBURL = findOldDatabase() else {
            Log.info(Log.migration, "No old SwiftData database found — skipping migration")
            return 0
        }

        Log.info(Log.migration, "Found old database at: \(oldDBURL.path)")
        return migrateFromOldDB(at: oldDBURL)
    }

    // MARK: - Private

    private func findOldDatabase() -> URL? {
        // SwiftData stores in:
        // ~/Library/Application Support/OakReader/default.store
        // or ~/Library/Containers/com.oakreader.OakReader/Data/Library/Application Support/OakReader/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first

        let candidates = [
            appSupport?.appendingPathComponent("OakReader/default.store"),
            appSupport?.appendingPathComponent("OakReader/OakReaderLibrary.store"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.oakreader.OakReader/Data/Library/Application Support/OakReader/default.store"),
        ].compactMap { $0 }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func migrateFromOldDB(at dbURL: URL) -> Int {
        // The old SwiftData database is a SQLite file. We'll read it directly
        // to extract library items and their file paths/bookmark data.
        // This avoids depending on SwiftData for the migration.
        guard let db = OldSQLiteReader(path: dbURL.path) else {
            Log.error(Log.migration, "Failed to open old database")
            return 0
        }
        defer { db.close() }

        let items = db.fetchLibraryItems()
        Log.info(Log.migration, "Found \(items.count) items to migrate")

        var migrated = 0
        for item in items {
            if migrateItem(item) {
                migrated += 1
            }
        }

        Log.info(Log.migration, "Successfully migrated \(migrated)/\(items.count) items")
        return migrated
    }

    private func migrateItem(_ item: OldLibraryItem) -> Bool {
        // Resolve the file URL from old data
        guard let sourceURL = resolveOldFileURL(item) else {
            Log.error(Log.migration, "Cannot resolve URL for: \(item.title)")
            return false
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            Log.error(Log.migration, "File not found: \(sourceURL.path)")
            return false
        }

        let docId = item.id
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
        let originalFileName = sourceURL.lastPathComponent
        let destURL = CatalogDatabase.attachmentFileURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey, fileName: originalFileName)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: itemStorageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.error(Log.migration, "Failed to copy \(item.title): \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return false
        }

        // Save cover image if we have it
        if let coverData = item.coverImageData {
            let coverURL = CatalogDatabase.attachmentCoverURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
            try? coverData.write(to: coverURL, options: .atomic)
        }

        let now = Date().iso8601String
        let attId = UUID()
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: item.title,
            author: item.author,
            lastOpenedAt: item.lastOpenedAt.map { $0.iso8601String },
            syncStatus: SyncStatus.local.rawValue,
            createdAt: item.dateAdded.iso8601String,
            updatedAt: now
        )

        let attRecord = AttachmentRecord(
            id: attId.uuidString,
            itemId: docId.uuidString,
            storageKey: attStorageKey,
            fileName: item.fileName,
            attachmentType: ItemType.pdf.rawValue,
            sourceURL: nil,
            fileSize: item.fileSize,
            pageCount: item.pageCount,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        store.insertItem(itemRecord, attachment: attRecord)
        return true
    }

    private func resolveOldFileURL(_ item: OldLibraryItem) -> URL? {
        // Try bookmark data first
        if let bookmarkData = item.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        // Try file path fallback
        if let path = item.filePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }
}

// MARK: - Old SQLite Reader (minimal, reads SwiftData tables directly)

/// Minimal SQLite reader for the old SwiftData database.
/// Uses the C SQLite API directly to avoid SwiftData dependency.
private class OldSQLiteReader {
    private var db: OpaquePointer?

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
    }

    func close() {
        sqlite3_close(db)
    }

    func fetchLibraryItems() -> [OldLibraryItem] {
        // SwiftData table name is typically ZPDFLIBRARYITEM (Core Data style)
        // Try common table naming patterns
        let tableNames = [
            "ZPDFLIBRARYITEM",
            "PDFLibraryItem",
            "ZPDFLIBRARY_ITEM"
        ]

        for tableName in tableNames {
            let items = queryItems(from: tableName)
            if !items.isEmpty { return items }
        }

        return []
    }

    private func queryItems(from table: String) -> [OldLibraryItem] {
        let sql = """
            SELECT Z_PK, ZFILEBOOKMARKDATA, ZFILENAME, ZFILEPATH,
                   ZTITLE, ZAUTHOR, ZDATEADDED, ZDATELASTOPENED,
                   ZPAGECOUNT, ZFILESIZE, ZISFAVORITE, ZCOVERIMAGEDATA
            FROM \(table)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [OldLibraryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let item = OldLibraryItem(
                id: UUID(), // Generate new UUID since SwiftData uses integer PK
                bookmarkData: blobColumn(stmt, col: 1),
                fileName: stringColumn(stmt, col: 2) ?? "unknown.pdf",
                filePath: stringColumn(stmt, col: 3),
                title: stringColumn(stmt, col: 4) ?? "Untitled",
                author: stringColumn(stmt, col: 5) ?? "",
                dateAdded: dateColumn(stmt, col: 6) ?? Date(),
                lastOpenedAt: dateColumn(stmt, col: 7),
                pageCount: Int(sqlite3_column_int(stmt, 8)),
                fileSize: sqlite3_column_int64(stmt, 9),
                coverImageData: blobColumn(stmt, col: 11)
            )
            results.append(item)
        }

        return results
    }

    private func stringColumn(_ stmt: OpaquePointer?, col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }

    private func blobColumn(_ stmt: OpaquePointer?, col: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, col) else { return nil }
        let len = sqlite3_column_bytes(stmt, col)
        guard len > 0 else { return nil }
        return Data(bytes: ptr, count: Int(len))
    }

    private func dateColumn(_ stmt: OpaquePointer?, col: Int32) -> Date? {
        let type = sqlite3_column_type(stmt, col)
        if type == SQLITE_FLOAT {
            // Core Data stores dates as NSTimeIntervalSinceReferenceDate (seconds since 2001-01-01)
            let interval = sqlite3_column_double(stmt, col)
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        return nil
    }
}

/// Represents an item from the old SwiftData library.
private struct OldLibraryItem {
    let id: UUID
    let bookmarkData: Data?
    let fileName: String
    let filePath: String?
    let title: String
    let author: String
    let dateAdded: Date
    let lastOpenedAt: Date?
    let pageCount: Int
    let fileSize: Int64
    let coverImageData: Data?
}
