import Foundation
import GRDB

/// Stateless CRUD for the word-lookup history (`word_lookups`). Mirrors the other
/// small stores. No scheduling — just save / fetch / delete.
struct WordLookupStore {
    let database: CatalogDatabase

    static func dedupeKey(itemId: String?, word: String) -> String {
        "\(itemId ?? "global")|\(word.lowercased())"
    }

    /// This document's lookups, newest first.
    func fetch(itemId: String) -> [WordLookup] {
        read {
            try WordLookupRecord
                .filter(WordLookupRecord.CodingKeys.itemId == itemId)
                .order(WordLookupRecord.CodingKeys.createdAt.desc)
                .fetchAll($0)
        }.map(Self.domain(from:))
    }

    /// Every lookup across all documents, newest first.
    func fetchAll() -> [WordLookup] {
        read {
            try WordLookupRecord
                .order(WordLookupRecord.CodingKeys.createdAt.desc)
                .fetchAll($0)
        }.map(Self.domain(from:))
    }

    /// Save a lookup, replacing any prior lookup of the same word in the same
    /// document so the history stays one-card-per-word.
    @discardableResult
    func save(_ lookup: WordLookup) -> Bool {
        do {
            let key = Self.dedupeKey(itemId: lookup.itemId, word: lookup.word)
            var record = Self.record(from: lookup, dedupeKey: key)
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM word_lookups WHERE dedupe_key = ?", arguments: [key])
                try record.insert(db)
            }
            return true
        } catch {
            Log.error(Log.store, "WordLookupStore.save failed: \(error)")
            return false
        }
    }

    @discardableResult
    func delete(id: String) -> Bool {
        write { try $0.execute(sql: "DELETE FROM word_lookups WHERE id = ?", arguments: [id]) }
    }

    /// Clear one document's history (or all of it when `itemId` is nil).
    @discardableResult
    func clear(itemId: String?) -> Bool {
        write {
            if let itemId {
                try $0.execute(sql: "DELETE FROM word_lookups WHERE item_id = ?", arguments: [itemId])
            } else {
                try $0.execute(sql: "DELETE FROM word_lookups")
            }
        }
    }

    // MARK: - Private

    private func read<T>(_ block: (Database) throws -> [T]) -> [T] {
        do { return try database.dbQueue.read(block) }
        catch { Log.error(Log.store, "WordLookupStore.read failed: \(error)"); return [] }
    }

    @discardableResult
    private func write(_ block: (Database) throws -> Void) -> Bool {
        do { try database.dbQueue.write(block); return true }
        catch { Log.error(Log.store, "WordLookupStore.write failed: \(error)"); return false }
    }

    static func domain(from r: WordLookupRecord) -> WordLookup {
        WordLookup(
            id: r.id, itemId: r.itemId, itemTitle: r.itemTitle, word: r.word,
            sentence: r.sentence, explanation: r.explanation,
            createdAt: Date(iso8601String: r.createdAt) ?? Date()
        )
    }

    static func record(from l: WordLookup, dedupeKey: String) -> WordLookupRecord {
        WordLookupRecord(
            id: l.id, userId: localUserId, itemId: l.itemId, itemTitle: l.itemTitle,
            word: l.word, sentence: l.sentence, explanation: l.explanation,
            dedupeKey: dedupeKey, createdAt: l.createdAt.iso8601String
        )
    }
}
