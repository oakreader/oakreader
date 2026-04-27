import Foundation
import GRDB
import PDFKit

@Observable
final class LibraryStore {
    let database: CatalogDatabase

    // Search & filter state
    var searchText: String = ""
    var currentFilter: LibraryFilter = .all
    var currentSort: LibrarySortOrder = .dateAdded
    var sortAscending: Bool = false
    var selectedCollection: PDFCollection?
    var selectedTags: Set<UUID> = []

    // Observation trigger — bump this to force computed properties to re-evaluate
    private(set) var revision: Int = 0

    init(database: CatalogDatabase) {
        self.database = database
    }

    // MARK: - Library Items

    var items: [PDFLibraryItem] {
        _ = revision
        return (try? fetchAllItems()) ?? []
    }

    var inboxCount: Int {
        _ = revision
        return (try? database.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM documents WHERE is_in_inbox = 1
            """) ?? 0
        }) ?? 0
    }

    var filteredItems: [PDFLibraryItem] {
        var results = items

        // Apply filter
        switch currentFilter {
        case .inbox:
            results = results.filter { $0.isInInbox }
        case .all:
            break
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            results = results.filter { $0.dateAdded >= cutoff }
        case .favorites:
            results = results.filter { $0.isFavorite }
        case .pdfs:
            results = results.filter { $0.documentType == .pdf }
        case .webSnapshots:
            results = results.filter { $0.documentType == .webSnapshot }
        case .videos:
            results = results.filter { $0.documentType == .embed }
        }

        // Apply collection filter
        if let collection = selectedCollection {
            results = results.filter { $0.collections.contains(where: { $0.id == collection.id }) }
        }

        // Apply tag filter — items must have ALL selected tags
        if !selectedTags.isEmpty {
            results = results.filter { item in
                selectedTags.allSatisfy { tagID in
                    item.tags.contains(where: { $0.id == tagID })
                }
            }
        }

        // Apply search (FTS5 or fallback)
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            results = results.filter {
                $0.title.lowercased().contains(query) ||
                $0.author.lowercased().contains(query) ||
                $0.fileName.lowercased().contains(query)
            }
        }

        // Sort
        results.sort { a, b in
            let cmp: Bool
            switch currentSort {
            case .dateAdded:  cmp = a.dateAdded < b.dateAdded
            case .dateOpened: cmp = (a.dateLastOpened ?? .distantPast) < (b.dateLastOpened ?? .distantPast)
            case .title:      cmp = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .author:     cmp = a.author.localizedCaseInsensitiveCompare(b.author) == .orderedAscending
            case .fileSize:   cmp = a.fileSize < b.fileSize
            }
            return sortAscending ? cmp : !cmp
        }

        return results
    }

    // MARK: - Fetch

    private func fetchAllItems() throws -> [PDFLibraryItem] {
        try database.dbQueue.read { db in
            let documents = try DocumentRecord.fetchAll(db)
            let allDocTags = try DocumentTagRecord.fetchAll(db)
            let allTags = try TagRecord.order(TagRecord.CodingKeys.position).fetchAll(db)
            let allDocCollections = try DocumentCollectionRecord.fetchAll(db)
            let allCollections = try CollectionRecord.order(CollectionRecord.CodingKeys.sortOrder).fetchAll(db)

            // Build lookup maps
            let tagMap = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, PDFTag(record: $0)) })
            let collMap = Dictionary(uniqueKeysWithValues: allCollections.map { ($0.id, PDFCollection(record: $0)) })

            var docTagsMap: [String: [PDFTag]] = [:]
            for dt in allDocTags {
                if let tag = tagMap[dt.tagId] {
                    docTagsMap[dt.documentId, default: []].append(tag)
                }
            }

            var docCollectionsMap: [String: [PDFCollection]] = [:]
            for dc in allDocCollections {
                if let coll = collMap[dc.collectionId] {
                    docCollectionsMap[dc.documentId, default: []].append(coll)
                }
            }

            return documents.map { doc in
                let tags = docTagsMap[doc.id] ?? []
                let collections = docCollectionsMap[doc.id] ?? []
                let coverData = Self.loadCoverData(storageKey: doc.storageKey)
                return PDFLibraryItem(record: doc, tags: tags, collections: collections, coverImageData: coverData)
            }
        }
    }

    // MARK: - CRUD

    @discardableResult
    func insertDocument(_ record: DocumentRecord) -> PDFLibraryItem? {
        do {
            var rec = record
            try database.dbQueue.write { db in
                try rec.insert(db)
            }
            revision += 1
            let coverData = Self.loadCoverData(storageKey: rec.storageKey)
            return PDFLibraryItem(record: rec, coverImageData: coverData)
        } catch {
            Log.error(Log.store, "insertDocument failed: \(error)")
            return nil
        }
    }

    func findItem(byStorageKey key: String) -> PDFLibraryItem? {
        items.first { $0.storageKey == key }
    }

    func findItem(byFileName fileName: String) -> PDFLibraryItem? {
        items.first { $0.fileName == fileName }
    }

    func removeItem(_ item: PDFLibraryItem) {
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [item.id.uuidString])
            }
            // Remove storage directory
            let dir = CatalogDatabase.documentDirectory(storageKey: item.storageKey)
            try? FileManager.default.removeItem(at: dir)
            revision += 1
        } catch {
            Log.error(Log.store, "removeItem failed: \(error)")
        }
    }

    func toggleFavorite(_ item: PDFLibraryItem) {
        let newValue = !item.isFavorite
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE documents SET is_favorite = ?, updated_at = ? WHERE id = ?",
                    arguments: [newValue, now, item.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "toggleFavorite failed: \(error)")
        }
    }

    func markOpened(_ item: PDFLibraryItem) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE documents SET date_last_opened = ?, updated_at = ? WHERE id = ?",
                    arguments: [now, now, item.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "markOpened failed: \(error)")
        }
    }

    func updateCover(_ item: PDFLibraryItem, imageData: Data) {
        let coverURL = CatalogDatabase.documentCoverURL(storageKey: item.storageKey)
        do {
            try imageData.write(to: coverURL, options: .atomic)
            revision += 1
        } catch {
            Log.error(Log.store, "updateCover failed: \(error)")
        }
    }

    // MARK: - Collections

    var collections: [PDFCollection] {
        _ = revision
        return (try? fetchAllCollections()) ?? []
    }

    var rootCollections: [PDFCollection] {
        collections.filter { $0.parentId == nil }
    }

    private func fetchAllCollections() throws -> [PDFCollection] {
        try database.dbQueue.read { db in
            let records = try CollectionRecord.order(CollectionRecord.CodingKeys.sortOrder).fetchAll(db)
            // Count items per collection
            let countRows = try Row.fetchAll(db, sql: """
                SELECT collection_id, COUNT(*) as cnt FROM document_collections GROUP BY collection_id
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
    func createCollection(name: String, icon: String = "folder") -> PDFCollection {
        let now = Date().iso8601String
        let record = CollectionRecord(
            id: UUID().uuidString,
            userId: localUserId,
            name: name,
            icon: icon,
            sortOrder: collections.count,
            parentId: nil,
            createdAt: now,
            updatedAt: now
        )
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.insert(db)
            }
            revision += 1
        } catch {
            Log.error(Log.store, "createCollection failed: \(error)")
        }
        return PDFCollection(record: record)
    }

    @discardableResult
    func createSubcollection(name: String, icon: String = "folder", parent: PDFCollection) -> PDFCollection {
        let now = Date().iso8601String
        let record = CollectionRecord(
            id: UUID().uuidString,
            userId: localUserId,
            name: name,
            icon: icon,
            sortOrder: parent.subcollections.count,
            parentId: parent.id.uuidString,
            createdAt: now,
            updatedAt: now
        )
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.insert(db)
            }
            revision += 1
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
            revision += 1
        } catch {
            Log.error(Log.store, "moveCollection failed: \(error)")
        }
    }

    func deleteCollection(_ collection: PDFCollection) {
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [collection.id.uuidString])
            }
            if selectedCollection?.id == collection.id {
                selectedCollection = nil
            }
            revision += 1
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
            revision += 1
        } catch {
            Log.error(Log.store, "renameCollection failed: \(error)")
        }
    }

    func addItem(_ item: PDFLibraryItem, to collection: PDFCollection) {
        // Check if already in collection
        if item.collections.contains(where: { $0.id == collection.id }) { return }
        let now = Date().iso8601String
        let junction = DocumentCollectionRecord(
            documentId: item.id.uuidString,
            collectionId: collection.id.uuidString,
            createdAt: now
        )
        do {
            try database.dbQueue.write { db in
                try junction.insert(db)
                // Archive from inbox when organized into a collection
                try db.execute(
                    sql: "UPDATE documents SET is_in_inbox = 0, updated_at = ? WHERE id = ?",
                    arguments: [now, item.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "addItem to collection failed: \(error)")
        }
    }

    func removeItem(_ item: PDFLibraryItem, from collection: PDFCollection) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM document_collections WHERE document_id = ? AND collection_id = ?",
                    arguments: [item.id.uuidString, collection.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "removeItem from collection failed: \(error)")
        }
    }

    /// Import all PDFs and HTML files from a folder, creating a collection named after the folder.
    @discardableResult
    func importFolder(_ folderURL: URL, importService: ImportService) -> Int {
        let folderName = folderURL.lastPathComponent
        let collection = createCollection(name: folderName, icon: "folder.fill")

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let supportedExtensions: Set<String> = ["pdf", "html", "htm"]
        var count = 0
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let item: PDFLibraryItem?
            if ext == "html" || ext == "htm" {
                item = importService.importWebSnapshot(from: fileURL)
            } else {
                item = importService.importPDF(from: fileURL)
            }
            if let item {
                addItem(item, to: collection)
                count += 1
            }
        }

        selectedCollection = collection
        return count
    }

    // MARK: - Tags

    var tags: [PDFTag] {
        _ = revision
        return (try? fetchAllTags()) ?? []
    }

    private func fetchAllTags() throws -> [PDFTag] {
        try database.dbQueue.read { db in
            let records = try TagRecord.order(TagRecord.CodingKeys.position).fetchAll(db)
            return records.map { PDFTag(record: $0) }
        }
    }

    @discardableResult
    func createTag(name: String, color: TagColor) -> PDFTag {
        let now = Date().iso8601String
        let record = TagRecord(
            id: UUID().uuidString,
            userId: localUserId,
            name: name,
            colorHex: color.hex,
            position: tags.count,
            createdAt: now,
            updatedAt: now
        )
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.insert(db)
            }
            revision += 1
        } catch {
            Log.error(Log.store, "createTag failed: \(error)")
        }
        return PDFTag(record: record)
    }

    func deleteTag(_ tag: PDFTag) {
        selectedTags.remove(tag.id)
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tag.id.uuidString])
            }
            revision += 1
        } catch {
            Log.error(Log.store, "deleteTag failed: \(error)")
        }
    }

    func renameTag(_ tag: PDFTag, to name: String) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE tags SET name = ?, updated_at = ? WHERE id = ?",
                    arguments: [name, now, tag.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "renameTag failed: \(error)")
        }
    }

    func updateTagColor(_ tag: PDFTag, to color: TagColor) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE tags SET color_hex = ?, updated_at = ? WHERE id = ?",
                    arguments: [color.hex, now, tag.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "updateTagColor failed: \(error)")
        }
    }

    func addTag(_ tag: PDFTag, to item: PDFLibraryItem) {
        if item.tags.contains(where: { $0.id == tag.id }) { return }
        let now = Date().iso8601String
        let junction = DocumentTagRecord(
            documentId: item.id.uuidString,
            tagId: tag.id.uuidString,
            createdAt: now
        )
        do {
            try database.dbQueue.write { db in
                try junction.insert(db)
            }
            revision += 1
        } catch {
            Log.error(Log.store, "addTag failed: \(error)")
        }
    }

    func removeTag(_ tag: PDFTag, from item: PDFLibraryItem) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM document_tags WHERE document_id = ? AND tag_id = ?",
                    arguments: [item.id.uuidString, tag.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "removeTag failed: \(error)")
        }
    }

    // MARK: - Cover helpers

    private static func loadCoverData(storageKey: String) -> Data? {
        let url = CatalogDatabase.documentCoverURL(storageKey: storageKey)
        return try? Data(contentsOf: url)
    }
}
