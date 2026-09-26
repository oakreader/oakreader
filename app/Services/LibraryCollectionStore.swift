import Foundation
import GRDB

extension LibraryStore {
    // MARK: - Collections

    /// Filled by `LibraryStore.refresh()`; read synchronously from view bodies.
    var collections: [PDFCollection] { loadedCollections }

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

    // MARK: - Mutations
    //
    // Every one of these was the same three steps: build a record, write it,
    // invalidate. They now build a wire value and hand it to one upsert, which
    // is why creating, renaming, re-parenting and re-ruling a collection are
    // four lines each rather than four near-identical twenty-line bodies.

    @discardableResult
    func createCollection(name: String, icon: String = "folder.fill",
                          source: String? = nil, sourceKey: String? = nil) -> PDFCollection {
        save(makeCollection(name: name, icon: icon, sortOrder: userCollections.count,
                            source: source, sourceKey: sourceKey))
    }

    @discardableResult
    func createSmartCollection(name: String, icon: String = "magnifyingglass",
                               rules: FilterRuleSet) -> PDFCollection {
        save(makeCollection(name: name, icon: icon, sortOrder: userCollections.count,
                            isSmart: true, filterRules: encode(rules)))
    }

    @discardableResult
    func createSubcollection(name: String, icon: String = "folder.fill", parent: PDFCollection,
                             source: String? = nil, sourceKey: String? = nil) -> PDFCollection {
        save(makeCollection(name: name, icon: icon, sortOrder: parent.subcollections.count,
                            parentId: parent.id.uuidString, source: source, sourceKey: sourceKey))
    }

    func updateSmartCollectionRules(_ collection: PDFCollection, rules: FilterRuleSet) {
        save(wire(collection, filterRules: encode(rules)))
    }

    func renameCollection(_ collection: PDFCollection, to name: String) {
        save(wire(collection, name: name))
    }

    func moveCollection(_ collection: PDFCollection, toParent newParent: PDFCollection?) {
        save(wire(collection, parentId: newParent?.id.uuidString ?? nil, clearParent: newParent == nil))
    }

    func deleteCollection(_ collection: PDFCollection) {
        // System collections are built in; deleting one would leave the sidebar
        // without a section it assumes exists.
        guard !collection.isSystem else { return }
        let id = collection.id.uuidString
        Task {
            await LibraryCatalog.deleteCollection(id: id)
            await MainActor.run { self.invalidate() }
        }
    }

    // MARK: - Membership

    func addItem(_ item: LibraryItem, to collection: PDFCollection) {
        // Already a member: the core would no-op anyway, but skipping the round
        // trip keeps a repeated drag free.
        guard !item.collections.contains(where: { $0.id == collection.id }) else { return }
        setMembership(item, collection, member: true)
    }

    func removeItem(_ item: LibraryItem, from collection: PDFCollection) {
        setMembership(item, collection, member: false)
    }

    private func setMembership(_ item: LibraryItem, _ collection: PDFCollection, member: Bool) {
        let itemId = item.id.uuidString
        let collectionId = collection.id.uuidString
        Task {
            await LibraryCatalog.setMembership(
                itemId: itemId, collectionId: collectionId, member: member)
            await MainActor.run { self.invalidate() }
        }
    }

    /// Supported file extensions for folder import.
    static let folderImportExtensions: Set<String> = {
        var exts: Set<String> = ["pdf", "html", "htm", "md", "markdown", "txt", "text"]
        exts.formUnion(ImportService.audioExtensions)
        return exts
    }()

    // MARK: - Private

    private func encode(_ rules: FilterRuleSet) -> String? {
        (try? JSONEncoder().encode(rules)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func makeCollection(
        name: String, icon: String, sortOrder: Int,
        parentId: String? = nil, isSmart: Bool = false,
        filterRules: String? = nil, source: String? = nil, sourceKey: String? = nil
    ) -> CatalogCollection {
        let now = Date().iso8601String
        return CatalogCollection(
            id: UUID().uuidString, name: name, icon: icon, sortOrder: sortOrder,
            parentId: parentId, isSmart: isSmart, isSystem: false,
            filterRules: filterRules, source: source, sourceKey: sourceKey,
            createdAt: now, updatedAt: now)
    }

    /// An existing collection as a wire value, with selected fields replaced.
    /// `clearParent` exists because nil means "leave alone" for every other
    /// argument, and moving a collection to the root has to mean nil parent.
    private func wire(
        _ c: PDFCollection, name: String? = nil, parentId: String?? = nil,
        filterRules: String? = nil, clearParent: Bool = false
    ) -> CatalogCollection {
        CatalogCollection(
            id: c.id.uuidString,
            name: name ?? c.name,
            icon: c.icon,
            sortOrder: c.sortOrder,
            parentId: clearParent ? nil : (parentId ?? c.parentId?.uuidString),
            isSmart: c.isSmart,
            isSystem: c.isSystem,
            filterRules: filterRules ?? c.filterRules.flatMap(encode),
            source: c.source,
            sourceKey: c.sourceKey,
            createdAt: Date().iso8601String,
            updatedAt: Date().iso8601String)
    }

    @discardableResult
    private func save(_ collection: CatalogCollection) -> PDFCollection {
        Task {
            await LibraryCatalog.upsert(collection)
            await MainActor.run { self.invalidate() }
        }
        // Returned immediately so callers can use it before the write lands;
        // the reload will replace it with the stored form.
        return PDFCollection(wire: collection)
    }

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
