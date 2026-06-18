import Foundation
import GRDB

/// A single saved word lookup — the simple, per-document history behind the
/// Translation panel and the global "Words" view. No spaced repetition: it's
/// just a record you can flip through like a flashcard (the sentence with the
/// word highlighted on the front, the saved explanation on the back).
struct WordLookup: Identifiable, Hashable {
    let id: String
    /// The document the word was looked up in. Nullable + `ON DELETE SET NULL`
    /// so the history survives deleting the document.
    var itemId: String?
    /// Denormalized document title, so the global view shows the source without a join.
    var itemTitle: String
    var word: String
    var sentence: String
    var explanation: String     // saved Markdown explanation
    var createdAt: Date

    /// Front Markdown: the sentence with the first occurrence of `word` bolded.
    var frontMarkdown: String {
        let base = sentence.isEmpty ? word : sentence
        guard !word.isEmpty, let range = base.range(of: word, options: .caseInsensitive) else {
            return base
        }
        return base.replacingCharacters(in: range, with: "**\(base[range])**")
    }
}

/// GRDB row for `word_lookups`. `dedupe_key` = `"<item|global>|<lowercased word>"`
/// so re-looking up the same word in the same document updates one row instead of
/// piling up duplicates.
struct WordLookupRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "word_lookups"

    var id: String
    var userId: String
    var itemId: String?
    var itemTitle: String
    var word: String
    var sentence: String
    var explanation: String
    var dedupeKey: String
    var createdAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, word, sentence, explanation
        case userId = "user_id"
        case itemId = "item_id"
        case itemTitle = "item_title"
        case dedupeKey = "dedupe_key"
        case createdAt = "created_at"
    }
}
