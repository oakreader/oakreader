import Foundation

/// Reference metadata and cite keys, held by the core.
///
/// Cite-key *generation* moved with the storage rather than staying here, and
/// that is the point: a key has to be unique across the library, and computing
/// a candidate on this side then writing it in a second call leaves a window
/// where two imports settle on the same one. The core does both at once.
enum ReferenceCatalog {
    /// An item's CSL JSON, or nil when it has no citation.
    static func metadata(forItemId itemId: String) async -> String? {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.referencesGet, params: RPC.ReferencesGetParams(itemId: itemId),
                as: RPC.ReferencesGetResult.self)
            return result.cslJson
        } catch {
            Log.error(Log.store, "references/get failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save an item's metadata. Throws so a failed save reaches the UI that
    /// asked for it rather than disappearing into a log line.
    static func save(cslJson: String, forItemId itemId: String, extra: String?) async throws {
        try await NodeBackend.shared.call(
            RPC.Method.referencesSave,
            params: RPC.ReferencesSaveParams(
                itemId: itemId, cslJson: cslJson, extra: extra,
                at: Date().iso8601String))
    }

    /// Give an item a cite key unless it already has one.
    @discardableResult
    static func assignCiteKey(forItemId itemId: String) async -> String? {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.citeKeysAssign,
                params: RPC.CiteKeysAssignParams(
                    itemId: itemId, at: Date().iso8601String),
                as: RPC.CiteKeysAssignResult.self)
            return result.key
        } catch {
            Log.error(Log.store, "citeKeys/assign failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The key this item's metadata would produce, without writing it.
    static func proposedCiteKey(forItemId itemId: String) async -> String? {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.citeKeysPropose, params: RPC.CiteKeysProposeParams(itemId: itemId),
                as: RPC.CiteKeysProposeResult.self)
            return result.key
        } catch {
            Log.error(Log.store, "citeKeys/propose failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save a user-typed key. Throws when another item already uses it.
    static func saveCiteKey(_ key: String, forItemId itemId: String) async throws {
        try await NodeBackend.shared.call(
            RPC.Method.citeKeysSave,
            params: RPC.CiteKeysSaveParams(
                key: key, itemId: itemId, at: Date().iso8601String))
    }
}
