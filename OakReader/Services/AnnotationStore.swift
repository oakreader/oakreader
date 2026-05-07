import Foundation
import GRDB

/// Stateless service for annotation CRUD operations against the `annotations` table.
struct AnnotationStore {
    let database: CatalogDatabase

    // MARK: - Fetch

    /// Load non-deleted annotations for an attachment, sorted by sort_index.
    func fetch(attachmentId: String) -> [AnnotationRecord] {
        do {
            return try database.dbQueue.read { db in
                try AnnotationRecord
                    .filter(AnnotationRecord.CodingKeys.attachmentId == attachmentId)
                    .filter(AnnotationRecord.CodingKeys.deletedAt == nil)
                    .order(AnnotationRecord.CodingKeys.sortIndex)
                    .fetchAll(db)
            }
        } catch {
            Log.error(Log.store, "AnnotationStore.fetch(attachmentId:) failed: \(error)")
            return []
        }
    }

    /// Load a single annotation by ID.
    func fetch(id: String) -> AnnotationRecord? {
        do {
            return try database.dbQueue.read { db in
                try AnnotationRecord.fetchOne(db, key: id)
            }
        } catch {
            Log.error(Log.store, "AnnotationStore.fetch(id:) failed: \(error)")
            return nil
        }
    }

    // MARK: - Upsert

    /// Insert or update an annotation record.
    @discardableResult
    func upsert(_ record: AnnotationRecord) -> Bool {
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.save(db)
            }
            return true
        } catch {
            Log.error(Log.store, "AnnotationStore.upsert failed: \(error)")
            return false
        }
    }

    // MARK: - Delete

    /// Soft-delete: set `deleted_at` timestamp.
    @discardableResult
    func softDelete(id: String) -> Bool {
        do {
            let now = Date().iso8601String
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE annotations SET deleted_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [now, now, id]
                )
            }
            return true
        } catch {
            Log.error(Log.store, "AnnotationStore.softDelete failed: \(error)")
            return false
        }
    }

    /// Hard-delete: remove the row entirely.
    @discardableResult
    func hardDelete(id: String) -> Bool {
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM annotations WHERE id = ?", arguments: [id])
            }
            return true
        } catch {
            Log.error(Log.store, "AnnotationStore.hardDelete failed: \(error)")
            return false
        }
    }

    // MARK: - Key Generation

    /// Generate a random 8-character alphanumeric key (matches `CatalogDatabase.generateStorageKey()` pattern).
    static func generateKey() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    // MARK: - Sort Index

    /// Encode a sort index as `PPPPP|YYYYYY|XXXXXX`.
    /// - Parameters:
    ///   - pageIndex: Zero-based page index
    ///   - bounds: Annotation bounds in PDF coordinate space
    ///   - pageHeight: Height of the page (used to invert Y for top-to-bottom sort)
    static func makeSortIndex(pageIndex: Int, bounds: CGRect, pageHeight: CGFloat) -> String {
        let page = String(format: "%05d", pageIndex)
        // Invert Y so annotations sort top-to-bottom (PDF origin is bottom-left)
        let invertedY = max(0, pageHeight - bounds.maxY)
        let y = String(format: "%06d", Int(invertedY))
        let x = String(format: "%06d", Int(bounds.minX))
        return "\(page)|\(y)|\(x)"
    }
}
