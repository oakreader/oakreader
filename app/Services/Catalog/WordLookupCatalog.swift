import Foundation

/// Word-lookup history, read and written through the sidecar rather than GRDB.
///
/// The first store to cross. What replaced `WordLookupStore` is not a thinner
/// database wrapper — it is *no* database access: the shell no longer opens
/// `library.sqlite` for this table at all, so there is exactly one process
/// holding the schema.
///
/// Every call is async now, which is the honest cost of the move. The old
/// store returned synchronously off a `DatabaseQueue`; a request that crosses
/// a process cannot. Call sites that used to read a property now await.
enum WordLookupCatalog {
    /// One document's lookups, newest first.
    static func list(itemId: String) async -> [WordLookup] {
        await fetch(params: RPC.WordLookupsListParams(itemId: itemId))
    }

    /// Every lookup across all documents, newest first.
    static func listAll() async -> [WordLookup] {
        await fetch(params: RPC.WordLookupsListParams(itemId: nil))
    }

    /// Save, replacing any prior lookup of the same word in the same document.
    static func save(_ lookup: WordLookup) async {
        await perform(RPC.Method.wordLookupsSave,
                      RPC.WordLookupsSaveParams(lookup: .init(lookup)))
    }

    static func delete(id: String) async {
        await perform(RPC.Method.wordLookupsDelete, RPC.WordLookupsDeleteParams(id: id))
    }

    /// Clear one document's history, or all of it when `itemId` is nil.
    static func clear(itemId: String?) async {
        await perform(RPC.Method.wordLookupsClear, RPC.WordLookupsClearParams(itemId: itemId))
    }

    // MARK: - Private

    private static func fetch(params: RPC.WordLookupsListParams) async -> [WordLookup] {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.wordLookupsList, params: params, as: RPC.WordLookupsListResult.self)
            return (result.lookups ?? []).map(\.domain)
        } catch {
            Log.error(Log.store, "wordLookups/list failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func perform<P: Encodable>(_ method: String, _ params: P) async {
        do {
            try await NodeBackend.shared.call(method, params: params)
        } catch {
            Log.error(Log.store, "\(method) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Wire ↔ domain

private extension CatalogWordLookup {
    /// Dates cross as ISO 8601 strings, which is also how the column stores
    /// them; converting at the edge keeps `WordLookup` a plain value type.
    init(_ lookup: WordLookup) {
        self.init(
            id: lookup.id,
            itemId: lookup.itemId,
            itemTitle: lookup.itemTitle,
            word: lookup.word,
            sentence: lookup.sentence,
            explanation: lookup.explanation,
            createdAt: lookup.createdAt.iso8601String
        )
    }

    var domain: WordLookup {
        WordLookup(
            id: id,
            itemId: itemId,
            itemTitle: itemTitle,
            word: word,
            sentence: sentence,
            explanation: explanation,
            createdAt: Date(iso8601String: createdAt) ?? Date()
        )
    }
}
