import Foundation
import GRDB

/// Generates and manages cite keys for library items.
///
/// **Formula**: `{auth}{TitleWords}{year}`
/// - `auth`: first author family name, lowercased, transliterated, particles stripped
/// - `TitleWords`: first 3 significant words (stop words filtered), CamelCase
/// - `year`: 4-digit year
///
/// Examples: `vaswaniAttentionAll2017`, `goodfellowDeepLearning2016`
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

        // No-author fallback: lowercase the first title word so it reads like `attentionAll2017`
        if authorPart.isEmpty, !titlePart.isEmpty {
            return Self.lowercaseFirstWord(titlePart) + yearPart
        }

        let base = authorPart + titlePart + yearPart
        return base.isEmpty ? "" : base
    }

    /// Fallback for when no CSLItem is available (plain strings).
    func generateBase(author: String, title: String?, year: Int?) -> String {
        let authorPart = Self.processAuthorName(author)
        let titlePart: String
        if let title, !title.isEmpty {
            titlePart = Self.extractTitleWordsFromString(title)
        } else {
            titlePart = ""
        }
        let yearPart = year.map { "\($0)" } ?? ""

        if authorPart.isEmpty, !titlePart.isEmpty {
            return Self.lowercaseFirstWord(titlePart) + yearPart
        }

        let base = authorPart + titlePart + yearPart
        return base.isEmpty ? "" : base
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

            let base: String
            if let cslJson = citation?.cslJson,
               let data = cslJson.data(using: .utf8),
               let csl = try? JSONDecoder().decode(CSLItem.self, from: data)
            {
                base = generateBase(csl: csl)
            } else {
                base = generateBase(
                    author: item.author,
                    title: item.title,
                    year: citation?.year
                )
            }

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

    // MARK: - Helpers

    /// Extract the first author's family name from a CSLItem, processed for use in a cite key.
    static func extractAuthorKey(csl: CSLItem) -> String {
        guard let firstAuthor = csl.author?.first else { return "" }
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

        // CamelCase each word: first letter uppercased, rest lowercased
        return significant.map { word in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst().lowercased()
        }.joined()
    }

    /// Lowercase only the first character of a string.
    /// Used for no-author fallback: `AttentionAll` → `attentionAll`.
    static func lowercaseFirstWord(_ str: String) -> String {
        guard let first = str.first else { return str }
        return first.lowercased() + str.dropFirst()
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
