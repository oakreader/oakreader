import Foundation
import GRDB

/// Stateless service for reference metadata CRUD operations.
/// Stores CSL JSON as the canonical representation in the `reference_metadata` table.
struct ReferenceService {
    let database: CatalogDatabase

    // MARK: - Fetch

    func fetchMetadata(forDocumentId documentId: String) -> ReferenceMetadata? {
        guard let record = try? database.dbQueue.read({ db in
            try ReferenceMetadataRecord
                .filter(ReferenceMetadataRecord.CodingKeys.documentId == documentId)
                .fetchOne(db)
        }) else { return nil }
        return ReferenceMetadata(jsonString: record.cslJson)
    }

    // MARK: - Save

    func saveMetadata(_ cslItem: CSLItem, forDocumentId documentId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(cslItem)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ReferenceError.encodingFailed
        }

        let now = Date().iso8601String

        try database.dbQueue.write { db in
            // Check if record exists
            let existing = try ReferenceMetadataRecord
                .filter(ReferenceMetadataRecord.CodingKeys.documentId == documentId)
                .fetchOne(db)

            var record = ReferenceMetadataRecord(
                documentId: documentId,
                cslJson: jsonString,
                cslType: cslItem.type,
                doi: cslItem.DOI,
                year: cslItem.issued?.year,
                containerTitle: cslItem.containerTitle,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )

            try record.save(db)

            // Update DocumentRecord author/title from CSL data
            let authorDisplay = (cslItem.author ?? [])
                .map { $0.displayString }
                .joined(separator: ", ")

            if !authorDisplay.isEmpty {
                try db.execute(
                    sql: "UPDATE documents SET author = ?, updated_at = ? WHERE id = ?",
                    arguments: [authorDisplay, now, documentId]
                )
            }
            if let title = cslItem.title, !title.isEmpty {
                try db.execute(
                    sql: "UPDATE documents SET title = ?, updated_at = ? WHERE id = ?",
                    arguments: [title, now, documentId]
                )
            }
        }
    }

    // MARK: - Delete

    func deleteMetadata(forDocumentId documentId: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM reference_metadata WHERE document_id = ?",
                arguments: [documentId]
            )
        }
    }
}

enum ReferenceError: Error {
    case encodingFailed
}
