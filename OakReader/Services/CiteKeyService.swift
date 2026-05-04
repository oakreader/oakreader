import Foundation
import GRDB

/// Generates and manages Zotero-style cite keys (e.g. "smith2024") for library items.
struct CiteKeyService {
    let database: CatalogDatabase

    // MARK: - Generate

    /// Generate a base cite key from author name and year: `{family_lowercase}{year}`.
    func generate(author: String, year: Int?) -> String {
        let family = author
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .components(separatedBy: .whitespaces).last ?? ""

        guard !family.isEmpty else { return "" }
        let yearStr = year.map { "\($0)" } ?? ""
        return family + yearStr
    }

    /// Generate a unique cite key, appending `a`, `b`, `c` suffixes to avoid collisions.
    func generateUnique(author: String, year: Int?, excludingItemId: String? = nil) throws -> String {
        let base = generate(author: author, year: year)
        guard !base.isEmpty else { return "" }

        return try database.dbQueue.read { db in
            var candidate = base
            var suffix = 0
            while true {
                var sql = "SELECT COUNT(*) FROM items WHERE cite_key = ?"
                var args: [DatabaseValueConvertible] = [candidate]
                if let excludeId = excludingItemId {
                    sql += " AND id != ?"
                    args.append(excludeId)
                }
                let count = try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
                if count == 0 { return candidate }
                let letter = String(UnicodeScalar(UInt8(97 + suffix)))
                candidate = base + letter
                suffix += 1
                if suffix >= 26 { return candidate }
            }
        }
    }

    // MARK: - Assign

    /// Read item + citation data, generate a unique cite key, and write it to the items table.
    /// No-op if the item already has a cite key.
    /// Falls back to the first word of the title when no author is available.
    func assignCiteKey(forItemId itemId: String) throws {
        try database.dbQueue.write { db in
            guard let item = try ItemRecord.fetchOne(db, key: itemId) else { return }
            guard item.citeKey == nil || item.citeKey?.isEmpty == true else { return }

            let citation = try CitationRecord
                .filter(CitationRecord.CodingKeys.itemId == itemId)
                .fetchOne(db)

            var cslType: String?
            let author = citation.flatMap { record -> String? in
                guard let data = record.cslJson.data(using: .utf8),
                      let csl = try? JSONDecoder().decode(CSLItem.self, from: data),
                      let firstAuthor = csl.author?.first else { return nil }
                cslType = csl.type
                return firstAuthor.family ?? firstAuthor.literal
            } ?? item.author

            let year = citation?.year
            let isVideo = cslType == "motion_picture"

            let base = generateBase(author: author, year: year, title: item.title, titleSuffix: isVideo)
            guard !base.isEmpty else { return }

            // Find unique key within the write transaction
            var candidate = base
            var suffix = 0
            while true {
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM items WHERE cite_key = ? AND id != ?",
                    arguments: [candidate, itemId]
                ) ?? 0
                if count == 0 { break }
                let letter = String(UnicodeScalar(UInt8(97 + suffix)))
                candidate = base + letter
                suffix += 1
                if suffix >= 26 { break }
            }

            try db.execute(
                sql: "UPDATE items SET cite_key = ?, updated_at = ? WHERE id = ?",
                arguments: [candidate, Date().iso8601String, itemId]
            )
        }
    }

    // MARK: - Lookup

    /// Find an item by its cite key.
    func findItem(byCiteKey key: String) throws -> ItemRecord? {
        try database.dbQueue.read { db in
            try ItemRecord
                .filter(ItemRecord.CodingKeys.citeKey == key)
                .fetchOne(db)
        }
    }

    // MARK: - Save (user edits)

    /// Save a user-provided cite key. Validates uniqueness.
    func saveCiteKey(_ key: String, forItemId itemId: String) throws {
        try database.dbQueue.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM items WHERE cite_key = ? AND id != ?",
                arguments: [key, itemId]
            ) ?? 0
            guard count == 0 else {
                throw CiteKeyError.duplicateKey(key)
            }
            try db.execute(
                sql: "UPDATE items SET cite_key = ?, updated_at = ? WHERE id = ?",
                arguments: [key, Date().iso8601String, itemId]
            )
        }
    }

    // MARK: - Private

    /// - Parameter titleSuffix: When `true`, appends `_firsttitleword` for disambiguation (used for videos).
    private func generateBase(author: String, year: Int?, title: String? = nil, titleSuffix: Bool = false) -> String {
        let family = author
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .components(separatedBy: .whitespaces).last ?? ""

        let base: String
        if !family.isEmpty {
            base = family
        } else if let title, !title.isEmpty {
            // Fallback: first meaningful word of title, lowercased
            let word = title
                .components(separatedBy: .whitespaces)
                .first { !$0.isEmpty }?
                .lowercased()
                .filter { $0.isLetter || $0.isNumber } ?? ""
            guard !word.isEmpty else { return "" }
            base = word
        } else {
            return ""
        }

        let yearStr = year.map { "\($0)" } ?? ""
        var key = base + yearStr

        // For videos, append first meaningful title word for disambiguation (e.g. "3blue1brown2024_linear")
        if titleSuffix, !family.isEmpty, let title, !title.isEmpty {
            let word = title
                .components(separatedBy: .whitespaces)
                .first { !$0.isEmpty }?
                .lowercased()
                .filter { $0.isLetter || $0.isNumber } ?? ""
            if !word.isEmpty {
                key += "_" + word
            }
        }

        return key
    }
}

enum CiteKeyError: LocalizedError {
    case duplicateKey(String)

    var errorDescription: String? {
        switch self {
        case .duplicateKey(let key):
            return "Cite key '\(key)' is already in use."
        }
    }
}
