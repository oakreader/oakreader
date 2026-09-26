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

    func saveMetadata(_ cslItem: CSLItem, forItemId itemId: String, extra: String? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(cslItem)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ReferenceError.encodingFailed
        }

        let now = Date().iso8601String

        // Extract identifiers from CSL fields and extra
        let isbn = cslItem.ISBN
        let issn = cslItem.ISSN
        let pmid = Self.extractPMID(from: cslItem, extra: extra)
        let arxivId = Self.extractArXivID(from: cslItem, extra: extra)

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
                abstract: cslItem.abstract,
                pmid: pmid,
                arxivId: arxivId,
                isbn: isbn,
                issn: issn,
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

            // Save extra field to items table
            if let extra, !extra.isEmpty {
                try db.execute(
                    sql: "UPDATE items SET extra = ?, updated_at = ? WHERE id = ?",
                    arguments: [extra, now, itemId]
                )
            }
        }

        // Auto-assign cite key if none exists
        try? citeKeyService.assignCiteKey(forItemId: itemId)
    }

    // MARK: - Extra Field Parsing

    /// Parse `extra` for "Key: Value" lines and merge into CSL JSON (only fills empty fields).
    static func mergeExtraFields(_ extra: String, into csl: inout CSLItem) {
        let lines = extra.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[trimmed.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            // Map known extra keys to CSL field keys
            if let cslKey = extraKeyToCSLField[key], csl[jsonKey: cslKey] == nil {
                csl[jsonKey: cslKey] = value
            }
        }
    }

    /// Extract PMID from CSL note field or extra text.
    static func extractPMID(from csl: CSLItem, extra: String?) -> String? {
        for source in [extra, csl.note] {
            guard let text = source else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("pmid:") {
                    let val = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { return val }
                }
            }
        }
        return nil
    }

    /// Extract arXiv ID from CSL note field or extra text.
    static func extractArXivID(from csl: CSLItem, extra: String?) -> String? {
        for source in [extra, csl.note] {
            guard let text = source else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let lower = trimmed.lowercased()
                if lower.hasPrefix("arxiv:") {
                    let val = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { return val }
                }
            }
        }
        return nil
    }

    /// Mapping from extra field keys (lowercased) to CSL JSON wire keys.
    private static let extraKeyToCSLField: [String: String] = [
        "doi": "DOI",
        "isbn": "ISBN",
        "issn": "ISSN",
        "volume": "volume",
        "issue": "issue",
        "pages": "page",
        "publisher": "publisher",
        "language": "language",
    ]

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
