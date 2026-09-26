import Foundation
import GRDB

/// Generates and manages cite keys for library items.
///
/// Follows the Better BibTeX default schema `auth.lower + shorttitle(3,3) + year`:
/// in BBT, `shorttitle(3,3)` selects 3 words and capitalizes 3 of them, so the title
/// words are CamelCase while the author is lowercase.
///
/// **Formula**: `{auth}{TitleWords}{year}`
/// - `auth`: first author family name, lowercased, transliterated, particles stripped
/// - `TitleWords`: first 3 significant words (stop words filtered), each capitalized
/// - `year`: 4-digit year
///
/// Examples: `vaswaniAttentionAllYou2017`, `goodfellowDeepLearning2016`
struct CiteKeyService {
    let database: CatalogDatabase

    // MARK: - Word Lists

    /// Common English stop words filtered from titles.
    private static let stopWords: Set<String> = [
        // Articles
        "a", "an", "the",
        // Conjunctions
        "and", "but", "or", "nor", "for", "yet", "so",
        // Prepositions
        "at", "by", "in", "of", "on", "to", "up", "as", "from", "into", "with",
        "about", "after", "before", "between", "through", "during", "without",
        "against", "along", "among", "around", "behind", "below", "beneath",
        "beside", "beyond", "down", "near", "off", "over", "past", "toward",
        "under", "upon",
        // Auxiliary verbs
        "is", "are", "was", "were", "be", "been", "being",
        "has", "have", "had", "do", "does", "did",
        "will", "would", "shall", "should", "may", "might", "can", "could",
        // Other common function words
        "it", "its", "not", "no", "than", "that", "this", "these", "those",
        "what", "which", "who", "whom", "how", "when", "where", "why",
    ]

    /// Name particles stripped from author family names.
    private static let nameParticles: Set<String> = [
        "von", "van", "de", "del", "della", "der", "di", "du", "el", "la", "le",
        "lo", "ten", "ter", "den", "het", "dos", "das", "do", "da", "af", "av",
    ]

    // MARK: - Generate from CSLItem

    /// Generate a base cite key from a CSLItem: `{auth}{TitleWords}{year}`.
    func generateBase(csl: CSLItem) -> String {
        let authorPart = Self.extractAuthorKey(csl: csl)
        let titlePart = Self.extractTitleWords(csl: csl)
        let yearPart = csl.issued?.year.map { "\($0)" } ?? ""
        // BBT default: lowercase author + CamelCase title words + year, simply concatenated.
        // A missing author just drops out (the key then starts with the capitalized title).
        return authorPart + titlePart + yearPart
    }

    /// Fallback for when no CSLItem is available (plain strings).
    func generateBase(author: String, title: String?, year: Int?) -> String {
        let authorPart = Self.processAuthorName(author)
        let titlePart = (title?.isEmpty == false) ? Self.extractTitleWordsFromString(title!) : ""
        let yearPart = year.map { "\($0)" } ?? ""
        return authorPart + titlePart + yearPart
    }

    // MARK: - Assign

    /// Read item + citation data, generate a unique cite key, and write it to the items table.
    /// No-op if the item already has a cite key.
    func assignCiteKey(forItemId itemId: String) throws {
        try database.dbQueue.write { db in
            guard let item = try ItemRecord.fetchOne(db, key: itemId) else { return }
            guard item.citeKey == nil || item.citeKey?.isEmpty == true else { return }

            let citation = try CitationRecord
                .filter(CitationRecord.CodingKeys.itemId == itemId)
                .fetchOne(db)

            let base = computeBase(item: item, citation: citation)
            guard !base.isEmpty else { return }

            let candidate = try uniqueCandidate(base: base, itemId: itemId, db: db)
            try db.execute(
                sql: "UPDATE items SET cite_key = ?, updated_at = ? WHERE id = ?",
                arguments: [candidate, Date().iso8601String, itemId]
            )
        }
    }

    /// Compute a fresh, unique cite key from the item's CURRENT metadata, WITHOUT writing.
    /// Used by the metadata panel's Regenerate action so the user can confirm before committing.
    /// Returns `nil` if there isn't enough metadata to form a key.
    func proposedKey(forItemId itemId: String) throws -> String? {
        try database.dbQueue.read { db in
            guard let item = try ItemRecord.fetchOne(db, key: itemId) else { return nil }
            let citation = try CitationRecord
                .filter(CitationRecord.CodingKeys.itemId == itemId)
                .fetchOne(db)
            let base = computeBase(item: item, citation: citation)
            guard !base.isEmpty else { return nil }
            return try uniqueCandidate(base: base, itemId: itemId, db: db)
        }
    }

    /// Build the base key (no uniqueness suffix) from an item and its citation row.
    /// Prefers the full CSL metadata; falls back to the item's plain author/title fields.
    private func computeBase(item: ItemRecord, citation: CitationRecord?) -> String {
        if let cslJson = citation?.cslJson,
           let data = cslJson.data(using: .utf8),
           let csl = try? JSONDecoder().decode(CSLItem.self, from: data)
        {
            return generateBase(csl: csl)
        }
        return generateBase(author: item.author, title: item.title, year: citation?.year)
    }

    /// Find a unique key derived from `base`, appending `a`/`b`/`c`… on collision.
    /// Excludes `itemId` so re-deriving an item's own existing key is not treated as a clash.
    private func uniqueCandidate(base: String, itemId: String, db: Database) throws -> String {
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
        return candidate
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

    // MARK: - Helpers

    /// Extract the first author's family name from a CSLItem, processed for use in a cite key.
    /// Includes non-dropping particle (e.g., "von Neumann" → "vonneumann").
    static func extractAuthorKey(csl: CSLItem) -> String {
        guard let firstAuthor = csl.author?.first else { return "" }

        // When the name has an explicit non-dropping particle, include it directly
        // without going through particle-stripping logic.
        if let ndp = firstAuthor.nonDroppingParticle, !ndp.isEmpty {
            let familyPart = firstAuthor.family ?? ""
            let combined = ndp + familyPart
            let latin = transliterate(combined)
            return alphanumericOnly(latin.lowercased())
        }

        let name = firstAuthor.family ?? firstAuthor.literal ?? ""
        return processAuthorName(name)
    }

    /// Transliterate, lowercase, strip particles, keep only alphanumeric characters.
    static func processAuthorName(_ name: String) -> String {
        let latin = transliterate(name)
        let lower = latin.lowercased()

        // Split into words, remove particles, rejoin
        let words = lower.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && !nameParticles.contains($0) }

        let joined = words.joined()
        return alphanumericOnly(joined)
    }

    /// Extract title words as CamelCase from a CSLItem.
    /// Prefers `shortTitle` if it has <= 5 words, otherwise uses the full title.
    /// Filters stop words and takes the first 3 significant words.
    static func extractTitleWords(csl: CSLItem) -> String {
        // Prefer shortTitle if concise enough
        if let short = csl.shortTitle, !short.isEmpty {
            let wordCount = short.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }.count
            if wordCount <= 5 {
                return extractTitleWordsFromString(short)
            }
        }

        guard let title = csl.title, !title.isEmpty else { return "" }
        return extractTitleWordsFromString(title)
    }

    /// Extract up to 3 significant words from a title string, returned as CamelCase.
    static func extractTitleWordsFromString(_ title: String) -> String {
        let latin = transliterate(title)

        // Split on non-alphanumeric (keeps words clean)
        let words = latin.components(separatedBy: .whitespaces)
            .flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }

        // Filter stop words and take first 3
        let significant = words
            .filter { !stopWords.contains($0.lowercased()) }
            .prefix(3)

        // Better BibTeX `shorttitle(3,3)`: capitalize each selected word (CamelCase) and
        // concatenate without separators, e.g. "Attention All You" -> "AttentionAllYou".
        return significant.map { word in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst().lowercased()
        }.joined()
    }

    /// Apple-native transliteration: any script → Latin → strip diacritics.
    static func transliterate(_ string: String) -> String {
        let mutable = NSMutableString(string: string)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return mutable as String
    }

    /// Keep only ASCII letters and digits.
    static func alphanumericOnly(_ string: String) -> String {
        string.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
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
