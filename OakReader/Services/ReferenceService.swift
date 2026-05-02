import Foundation
import GRDB

/// Stateless service for reference metadata CRUD operations.
/// Stores CSL JSON as the canonical representation in the `citations` table.
struct ReferenceService {
    let database: CatalogDatabase
    private var citeKeyService: CiteKeyService { CiteKeyService(database: database) }

    // MARK: - Fetch

    func fetchMetadata(forItemId itemId: String) -> ReferenceMetadata? {
        guard let record = try? database.dbQueue.read({ db in
            try CitationRecord
                .filter(CitationRecord.CodingKeys.itemId == itemId)
                .fetchOne(db)
        }) else { return nil }
        return ReferenceMetadata(jsonString: record.cslJson)
    }

    // MARK: - Save

    func saveMetadata(_ cslItem: CSLItem, forItemId itemId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(cslItem)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ReferenceError.encodingFailed
        }

        let now = Date().iso8601String

        try database.dbQueue.write { db in
            // Check if record exists
            let existing = try CitationRecord
                .filter(CitationRecord.CodingKeys.itemId == itemId)
                .fetchOne(db)

            var record = CitationRecord(
                itemId: itemId,
                cslJson: jsonString,
                cslType: cslItem.type,
                doi: cslItem.DOI,
                year: cslItem.issued?.year,
                containerTitle: cslItem.containerTitle,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )

            try record.save(db)

            // Update ItemRecord author/title from CSL data
            let authorDisplay = (cslItem.author ?? [])
                .map { $0.displayString }
                .joined(separator: ", ")

            if !authorDisplay.isEmpty {
                try db.execute(
                    sql: "UPDATE items SET author = ?, updated_at = ? WHERE id = ?",
                    arguments: [authorDisplay, now, itemId]
                )
            }
            if let title = cslItem.title, !title.isEmpty {
                try db.execute(
                    sql: "UPDATE items SET title = ?, updated_at = ? WHERE id = ?",
                    arguments: [title, now, itemId]
                )
            }
        }

        // Auto-assign cite key if none exists
        try? citeKeyService.assignCiteKey(forItemId: itemId)
    }

    // MARK: - Delete

    func deleteMetadata(forItemId itemId: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM citations WHERE item_id = ?",
                arguments: [itemId]
            )
        }
    }
}

enum ReferenceError: Error {
    case encodingFailed
}
