import Foundation
import GRDB

// MARK: - Resolution Logic

/// Resolves user-provided identifiers (UUID, name, cite key, prefix) to database records.
struct CLIResolver {
    let db: CLIDatabase

    // MARK: - Item Resolution

    func resolveItem(_ input: String) throws -> CLIItem {
        let matches = try findItems(input)
        switch matches.count {
        case 0:
            throw ResolveError.notFound("item", input)
        case 1:
            return matches[0]
        default:
            throw ResolveError.ambiguous("item", input, matches.map { "\($0.title) [\($0.id.prefix(8))]" })
        }
    }

    private func findItems(_ input: String) throws -> [CLIItem] {
        try db.dbQueue.read { db in
            // 1. Exact UUID
            if let item = try CLIItem.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [input]) {
                return [item]
            }

            // Also try lowercased UUID
            if let item = try CLIItem.fetchOne(db, sql: "SELECT * FROM items WHERE LOWER(id) = LOWER(?)", arguments: [input]) {
                return [item]
            }

            // 2. Exact name (case-insensitive)
            let byName = try CLIItem.fetchAll(db, sql: "SELECT * FROM items WHERE LOWER(title) = LOWER(?)", arguments: [input])
            if !byName.isEmpty { return byName }

            // 3. Cite key (exact, case-insensitive)
            let byCiteKey = try CLIItem.fetchAll(db, sql: "SELECT * FROM items WHERE LOWER(cite_key) = LOWER(?)", arguments: [input])
            if !byCiteKey.isEmpty { return byCiteKey }

            // 4. Prefix match on title
            let byPrefix = try CLIItem.fetchAll(db, sql: "SELECT * FROM items WHERE LOWER(title) LIKE LOWER(?) || '%'", arguments: [input])
            if !byPrefix.isEmpty { return byPrefix }

            // 5. Prefix match on cite key
            let byCiteKeyPrefix = try CLIItem.fetchAll(db, sql: "SELECT * FROM items WHERE LOWER(cite_key) LIKE LOWER(?) || '%'", arguments: [input])
            if !byCiteKeyPrefix.isEmpty { return byCiteKeyPrefix }

            return []
        }
    }

    // MARK: - Collection Resolution

    func resolveCollection(_ input: String) throws -> CLICollection {
        let matches = try findCollections(input)
        switch matches.count {
        case 0:
            throw ResolveError.notFound("collection", input)
        case 1:
            return matches[0]
        default:
            throw ResolveError.ambiguous("collection", input, matches.map { "\($0.name) [\($0.id.prefix(8))]" })
        }
    }

    private func findCollections(_ input: String) throws -> [CLICollection] {
        try db.dbQueue.read { db in
            // 1. Exact UUID
            if let c = try CLICollection.fetchOne(db, sql: "SELECT * FROM collections WHERE id = ?", arguments: [input]) {
                return [c]
            }

            // 2. Exact name (case-insensitive)
            let byName = try CLICollection.fetchAll(db, sql: "SELECT * FROM collections WHERE LOWER(name) = LOWER(?) AND is_system = 0", arguments: [input])
            if !byName.isEmpty { return byName }

            // 3. Prefix match
            let byPrefix = try CLICollection.fetchAll(db, sql: "SELECT * FROM collections WHERE LOWER(name) LIKE LOWER(?) || '%' AND is_system = 0", arguments: [input])
            if !byPrefix.isEmpty { return byPrefix }

            return []
        }
    }

    // MARK: - Tag Resolution

    func resolveTag(_ input: String) throws -> CLIPropertyOption {
        let matches = try findTags(input)
        switch matches.count {
        case 0:
            throw ResolveError.notFound("tag", input)
        case 1:
            return matches[0]
        default:
            throw ResolveError.ambiguous("tag", input, matches.map { "\($0.name) [\($0.id.prefix(8))]" })
        }
    }

    private func findTags(_ input: String) throws -> [CLIPropertyOption] {
        try db.dbQueue.read { db in
            // 1. Exact UUID
            if let t = try CLIPropertyOption.fetchOne(db, sql: """
                SELECT po.* FROM property_options po
                JOIN properties p ON p.id = po.property_id AND p.name = 'Tags'
                WHERE po.id = ?
            """, arguments: [input]) {
                return [t]
            }

            // 2. Exact name (case-insensitive)
            let byName = try CLIPropertyOption.fetchAll(db, sql: """
                SELECT po.* FROM property_options po
                JOIN properties p ON p.id = po.property_id AND p.name = 'Tags'
                WHERE LOWER(po.name) = LOWER(?)
            """, arguments: [input])
            if !byName.isEmpty { return byName }

            // 3. Prefix match
            let byPrefix = try CLIPropertyOption.fetchAll(db, sql: """
                SELECT po.* FROM property_options po
                JOIN properties p ON p.id = po.property_id AND p.name = 'Tags'
                WHERE LOWER(po.name) LIKE LOWER(?) || '%'
            """, arguments: [input])
            if !byPrefix.isEmpty { return byPrefix }

            return []
        }
    }

    // MARK: - Status Resolution

    func resolveStatus(_ input: String) throws -> CLIPropertyOption {
        let statuses = try db.fetchAllStatuses()

        // Exact match
        if let s = statuses.first(where: { $0.name.lowercased() == input.lowercased() }) {
            return s
        }

        // Prefix match
        let prefixMatches = statuses.filter { $0.name.lowercased().hasPrefix(input.lowercased()) }
        switch prefixMatches.count {
        case 0:
            let validValues = statuses.map(\.name).joined(separator: ", ")
            throw ResolveError.invalidStatus(input, validValues)
        case 1:
            return prefixMatches[0]
        default:
            throw ResolveError.ambiguous("status", input, prefixMatches.map(\.name))
        }
    }

    /// Resolve a collection for the --parent flag (used in collection creation)
    func resolveParentCollection(_ input: String) throws -> CLICollection {
        try resolveCollection(input)
    }
}

// MARK: - Errors

enum ResolveError: LocalizedError {
    case notFound(String, String)
    case ambiguous(String, String, [String])
    case invalidStatus(String, String)

    var errorDescription: String? {
        switch self {
        case .notFound(let type, let input):
            return "No \(type) found matching '\(input)'."
        case .ambiguous(let type, let input, let options):
            var msg = "Ambiguous \(type) '\(input)'. Did you mean one of:\n"
            for opt in options {
                msg += "  - \(opt)\n"
            }
            return msg
        case .invalidStatus(let input, let valid):
            return "Invalid status '\(input)'. Valid values: \(valid)"
        }
    }
}
