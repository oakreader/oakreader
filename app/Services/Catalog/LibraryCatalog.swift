import Foundation

/// The library, read from the core.
///
/// The shape here is dictated by SwiftUI, not by preference. `LibraryStore.items`
/// is a synchronous computed property read directly from view bodies, and there
/// are only two of those — but a view body cannot await, so turning the whole
/// library into an async read would mean rewriting every list, grid and
/// sidebar that touches it.
///
/// So the cache stays synchronous and only its *filling* becomes async. Views
/// keep reading a plain array; a refresh replaces it and bumps the observation
/// revision, which is exactly what `invalidate()` already did when the fetch
/// was a local SQLite read.
///
/// The cost is a first paint that can show an empty library for one round trip.
/// `AppState` warms the cache at launch so the library view finds it populated;
/// if it ever does not, an empty list that fills in beats a blocked main thread.
enum LibraryCatalog {
    /// Every live item with its attachments, memberships, citation and properties.
    static func items() async -> [CatalogItem] {
        await fetch(trashed: false)
    }

    /// Items in the trash, most recently deleted first.
    static func trashedItems() async -> [CatalogItem] {
        await fetch(trashed: true)
    }

    static func find(by handle: Handle) async -> CatalogItem? {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.itemsFind, params: handle.params, as: RPC.ItemsFindResult.self)
            return result.item
        } catch {
            Log.error(Log.store, "items/find failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// How an item can be looked up. Modelled as a type so a call site cannot
    /// pass a `source` without its key.
    enum Handle {
        case id(String)
        case citeKey(String)
        case storageKey(String)
        case fileName(String)
        case sourceURL(String)
        case source(String, key: String)

        var params: RPC.ItemsFindParams {
            switch self {
            case .id(let v):          return .init(by: "id", value: v, sourceKey: nil)
            case .citeKey(let v):     return .init(by: "citeKey", value: v, sourceKey: nil)
            case .storageKey(let v):  return .init(by: "storageKey", value: v, sourceKey: nil)
            case .fileName(let v):    return .init(by: "fileName", value: v, sourceKey: nil)
            case .sourceURL(let v):   return .init(by: "sourceUrl", value: v, sourceKey: nil)
            case .source(let v, let key): return .init(by: "source", value: v, sourceKey: key)
            }
        }
    }

    // MARK: - Mutations

    static func insert(_ item: CatalogItem) async {
        await perform(RPC.Method.itemsInsert, RPC.ItemsInsertParams(item: item))
    }

    /// Update one scalar field. Text and numeric values travel in separate
    /// slots because the column decides which applies.
    static func update(id: String, field: String, string: String?) async {
        await perform(RPC.Method.itemsUpdateField, RPC.ItemsUpdateFieldParams(
            id: id, field: field, stringValue: string, numberValue: nil,
            at: Date().iso8601String))
    }

    static func update(id: String, field: String, number: Double?) async {
        await perform(RPC.Method.itemsUpdateField, RPC.ItemsUpdateFieldParams(
            id: id, field: field, stringValue: nil, numberValue: number,
            at: Date().iso8601String))
    }

    /// Move to or out of the trash. The rows survive either way, which is what
    /// makes restore real rather than a re-import.
    static func setTrashed(ids: [String], trashed: Bool) async {
        await perform(RPC.Method.itemsSetTrashed, RPC.ItemsSetTrashedParams(
            ids: ids, trashed: trashed, at: Date().iso8601String))
    }

    /// Permanent. Cascades to attachments, annotations, memberships, citations.
    static func remove(ids: [String]) async {
        await perform(RPC.Method.itemsRemove, RPC.ItemsRemoveParams(ids: ids))
    }

    /// Fold duplicates into a keeper. Rows only; the caller moves the files.
    static func merge(keeperId: String, duplicateIds: [String]) async {
        await perform(RPC.Method.itemsMerge, RPC.ItemsMergeParams(
            keeperId: keeperId, duplicateIds: duplicateIds, at: Date().iso8601String))
    }

    // MARK: - Collections

    static func collections() async -> [CatalogCollection] {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.collectionsList, params: RPC.CollectionsListParams(),
                as: RPC.CollectionsListResult.self)
            return result.collections ?? []
        } catch {
            Log.error(Log.store, "collections/list failed: \(error.localizedDescription)")
            return []
        }
    }

    static func upsert(_ collection: CatalogCollection) async {
        await perform(RPC.Method.collectionsUpsert,
                      RPC.CollectionsUpsertParams(collection: collection))
    }

    static func deleteCollection(id: String) async {
        await perform(RPC.Method.collectionsDelete, RPC.CollectionsDeleteParams(id: id))
    }

    /// Add or remove one item. Adding twice is a no-op, not a failure.
    static func setMembership(itemId: String, collectionId: String, member: Bool) async {
        await perform(RPC.Method.collectionsSetMembership,
                      RPC.CollectionsSetMembershipParams(
                        itemId: itemId, collectionId: collectionId,
                        member: member, at: Date().iso8601String))
    }

    // MARK: - Private

    private static func fetch(trashed: Bool) async -> [CatalogItem] {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.itemsList, params: RPC.ItemsListParams(trashed: trashed),
                as: RPC.ItemsListResult.self)
            return result.items ?? []
        } catch {
            Log.error(Log.store, "items/list failed: \(error.localizedDescription)")
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
