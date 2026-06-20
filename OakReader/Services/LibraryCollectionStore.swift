import Foundation
import AppKit
import GRDB

extension LibraryStore {
    // MARK: - Collections

    var collections: [PDFCollection] {
        _ = revision
        if let cached = collectionsCache, cached.revision == revision {
            return cached.collections
        }
        let result = (try? fetchAllCollections()) ?? []
        collectionsCache = (revision: revision, collections: result)
        return result
    }

    func findCollection(bySource source: String, sourceKey: String) -> PDFCollection? {
        collections.first { $0.source == source && $0.sourceKey == sourceKey }
    }

    /// System smart collections (All Items, Recently Added, etc.).
    var systemSmartCollections: [PDFCollection] {
        collections.filter { $0.isSystem && $0.isSmart }
    }

    /// User-created collections (both traditional and smart, non-system).
    var userCollections: [PDFCollection] {
        collections.filter { !$0.isSystem }
    }

    var rootCollections: [PDFCollection] {
        collections.filter { $0.parentId == nil && !$0.isSystem }
    }

    func fetchAllCollections() throws -> [PDFCollection] {
        try database.dbQueue.read { db in
            let records = try CollectionRecord.order(CollectionRecord.CodingKeys.sortOrder).fetchAll(db)
            // Count items per collection
            let countRows = try Row.fetchAll(db, sql: """
                SELECT collection_id, COUNT(*) as cnt FROM collection_items GROUP BY collection_id
            """)
            var itemCounts: [String: Int] = [:]
            for row in countRows {
                itemCounts[row["collection_id"]] = row["cnt"]
            }
            return buildCollectionTree(from: records, itemCounts: itemCounts)
        }
    }

    private func buildCollectionTree(from records: [CollectionRecord], itemCounts: [String: Int]) -> [PDFCollection] {
        var childrenMap: [String?: [CollectionRecord]] = [:]
        for r in records {
            childrenMap[r.parentId, default: []].append(r)
        }

        func build(parentId: String?) -> [PDFCollection] {
            (childrenMap[parentId] ?? []).map { record in
                let subs = build(parentId: record.id)
                return PDFCollection(record: record, subcollections: subs, itemCount: itemCounts[record.id] ?? 0)
            }
        }

        return records.map { record in
            let subs = build(parentId: record.id)
            return PDFCollection(record: record, subcollections: subs, itemCount: itemCounts[record.id] ?? 0)
        }
    }

    @discardableResult
    func createCollection(name: String, icon: String = "folder.fill", source: String? = nil, sourceKey: String? = nil) -> PDFCollection {
        let now = Date().iso8601String
        let record = CollectionRecord(
            id: UUID().uuidString,
            userId: localUserId,
            name: name,
            icon: icon,
            sortOrder: userCollections.count,
            parentId: nil,
            isSmart: false,
            isSystem: false,
            filterRules: nil,
            createdAt: now,
            updatedAt: now,
            source: source,
            sourceKey: sourceKey
        )
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.insert(db)
            }
            invalidate()
        } catch {
            Log.error(Log.store, "createCollection failed: \(error)")
        }
        return PDFCollection(record: record)
    }

    @discardableResult
    func createSmartCollection(name: String, icon: String = "magnifyingglass", rules: FilterRuleSet) -> PDFCollection {
        let now = Date().iso8601String
        let rulesJSON = (try? JSONEncoder().encode(rules)).flatMap { String(data: $0, encoding: .utf8) }
        let record = CollectionRecord(
            id: UUID().uuidString,
            userId: localUserId,
            name: name,
            icon: icon,
            sortOrder: userCollections.count,
            parentId: nil,
            isSmart: true,
            isSystem: false,
            filterRules: rulesJSON,
            createdAt: now,
            updatedAt: now
        )
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.insert(db)
            }
            invalidate()
        } catch {
            Log.error(Log.store, "createSmartCollection failed: \(error)")
        }
        return PDFCollection(record: record)
    }

    func updateSmartCollectionRules(_ collection: PDFCollection, rules: FilterRuleSet) {
        let now = Date().iso8601String
        let rulesJSON = (try? JSONEncoder().encode(rules)).flatMap { String(data: $0, encoding: .utf8) }
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE collections SET filter_rules = ?, updated_at = ? WHERE id = ?",
                    arguments: [rulesJSON, now, collection.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "updateSmartCollectionRules failed: \(error)")
        }
    }

    @discardableResult
    func createSubcollection(name: String, icon: String = "folder.fill", parent: PDFCollection, source: String? = nil, sourceKey: String? = nil) -> PDFCollection {
        let now = Date().iso8601String
        let record = CollectionRecord(
            id: UUID().uuidString,
            userId: localUserId,
            name: name,
            icon: icon,
            sortOrder: parent.subcollections.count,
            parentId: parent.id.uuidString,
            isSmart: false,
            isSystem: false,
            filterRules: nil,
            createdAt: now,
            updatedAt: now,
            source: source,
            sourceKey: sourceKey
        )
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.insert(db)
            }
            invalidate()
        } catch {
            Log.error(Log.store, "createSubcollection failed: \(error)")
        }
        return PDFCollection(record: record)
    }

    func moveCollection(_ collection: PDFCollection, toParent newParent: PDFCollection?) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE collections SET parent_id = ?, updated_at = ? WHERE id = ?",
                    arguments: [newParent?.id.uuidString, now, collection.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "moveCollection failed: \(error)")
        }
    }

    func deleteCollection(_ collection: PDFCollection) {
        guard !collection.isSystem else { return }
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [collection.id.uuidString])
            }
            if selectedCollectionId == collection.id {
                selectedCollectionId = SystemCollectionID.readingList
            }
            invalidate()
        } catch {
            Log.error(Log.store, "deleteCollection failed: \(error)")
        }
    }

    func renameCollection(_ collection: PDFCollection, to name: String) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE collections SET name = ?, updated_at = ? WHERE id = ?",
                    arguments: [name, now, collection.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "renameCollection failed: \(error)")
        }
    }

    func addItem(_ item: LibraryItem, to collection: PDFCollection) {
        // Check if already in collection
        if item.collections.contains(where: { $0.id == collection.id }) { return }
        let now = Date().iso8601String
        let junction = CollectionItemRecord(
            itemId: item.id.uuidString,
            collectionId: collection.id.uuidString,
            createdAt: now
        )
        do {
            try database.dbQueue.write { db in
                try junction.insert(db)
            }
            invalidate()
        } catch {
            Log.error(Log.store, "addItem to collection failed: \(error)")
        }
    }

    func removeItem(_ item: LibraryItem, from collection: PDFCollection) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM collection_items WHERE item_id = ? AND collection_id = ?",
                    arguments: [item.id.uuidString, collection.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "removeItem from collection failed: \(error)")
        }
    }

    /// Supported file extensions for folder import.
    static let folderImportExtensions: Set<String> = {
        var exts: Set<String> = ["pdf", "html", "htm", "md", "markdown", "txt", "text"]
        exts.formUnion(ImportService.audioExtensions)
        return exts
    }()

    /// Import all supported files from a folder, creating a collection named after the folder.
    @discardableResult
    func importFolder(_ folderURL: URL, importService: ImportService) async -> Int {
        let folderName = folderURL.lastPathComponent
        let collection = createCollection(name: folderName, icon: "folder.fill")

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        // Collect file URLs first (enumerator is not Sendable)
        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if Self.folderImportExtensions.contains(ext) {
                fileURLs.append(fileURL)
            }
        }

        var count = 0
        for fileURL in fileURLs {
            let item = await importService.importFileAsync(from: fileURL)
            if let item {
                addItem(item, to: collection)
                count += 1
            }
        }

        selectedCollectionId = collection.id
        return count
    }

}
