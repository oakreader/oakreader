import Foundation
import GRDB

extension LibraryStore {
    // MARK: - Fetch

    func fetchAllItems() throws -> [LibraryItem] {
        try database.dbQueue.read { db in
            let records = try ItemRecord.filter(ItemRecord.CodingKeys.deletedAt == nil).fetchAll(db)
            let allAttachments = try AttachmentRecord.fetchAll(db)
            let allCollectionItems = try CollectionItemRecord.fetchAll(db)
            let allCollections = try CollectionRecord.order(CollectionRecord.CodingKeys.sortOrder).fetchAll(db)
            let allCitations = try CitationRecord.fetchAll(db)

            // Property values: join item_property_values with property_options and properties
            let allValues = try Row.fetchAll(db, sql: """
                SELECT
                    ipv.id AS value_id,
                    ipv.item_id,
                    ipv.property_id,
                    ipv.option_id,
                    ipv.text_value,
                    p.name AS property_name,
                    p.type AS property_type,
                    po.id AS po_id,
                    po.name AS option_name,
                    po.color_hex AS option_color_hex,
                    po.position AS option_position
                FROM item_property_values ipv
                JOIN properties p ON p.id = ipv.property_id
                LEFT JOIN property_options po ON po.id = ipv.option_id
            """)

            // Build attachments per item
            var itemAttachmentsMap: [String: [AttachmentRecord]] = [:]
            for att in allAttachments {
                itemAttachmentsMap[att.itemId, default: []].append(att)
            }

            // Build lookup maps
            let collMap = Dictionary(uniqueKeysWithValues: allCollections.map { ($0.id, PDFCollection(record: $0)) })

            var citationMap: [String: ReferenceMetadata] = [:]
            for record in allCitations {
                if let meta = ReferenceMetadata(jsonString: record.cslJson) {
                    citationMap[record.itemId] = meta
                }
            }

            var itemCollectionsMap: [String: [PDFCollection]] = [:]
            for ci in allCollectionItems {
                if let coll = collMap[ci.collectionId] {
                    itemCollectionsMap[ci.itemId, default: []].append(coll)
                }
            }

            // Build property values per item
            var itemPropertyValuesMap: [String: [PropertyValue]] = [:]
            for row in allValues {
                let itemId: String = row["item_id"]
                let option: PropertyOption?
                if let poId: String = row["po_id"] {
                    option = PropertyOption(
                        id: UUID(uuidString: poId) ?? UUID(),
                        propertyId: UUID(uuidString: row["property_id"]) ?? UUID(),
                        name: row["option_name"],
                        colorHex: row["option_color_hex"],
                        position: row["option_position"]
                    )
                } else {
                    option = nil
                }

                let propValue = PropertyValue(
                    id: UUID(uuidString: row["value_id"]) ?? UUID(),
                    propertyId: UUID(uuidString: row["property_id"]) ?? UUID(),
                    propertyName: row["property_name"],
                    propertyType: PropertyType(rawValue: row["property_type"]) ?? .text,
                    option: option,
                    textValue: row["text_value"]
                )
                itemPropertyValuesMap[itemId, default: []].append(propValue)
            }

            return records.map { item in
                let attRecords = itemAttachmentsMap[item.id] ?? []
                let attachments = attRecords.map { Attachment(record: $0, itemStorageKey: item.storageKey) }
                let propValues = itemPropertyValuesMap[item.id] ?? []
                let collections = itemCollectionsMap[item.id] ?? []
                let citation = citationMap[item.id]
                // Covers are NOT loaded here: at 10k items that would pin every cover image in
                // memory (hundreds of MB) and re-read them all from disk on each invalidate().
                // The views that actually show a cover (card grid, sidebar) load it lazily from
                // `attachment.coverURL`, decoded off-main and cached. The list view never needs it.
                return LibraryItem(
                    record: item,
                    attachments: attachments,
                    propertyValues: propValues,
                    collections: collections,
                    coverImageData: nil,
                    referenceMetadata: citation
                )
            }
        }
    }

    // MARK: - Single-Item Lookup

    /// These search the in-memory library rather than the database.
    ///
    /// They used to be cache-first with a SQL fallback, because the cache held
    /// only whatever a previous fetch had loaded. `loadedItems` is the whole
    /// live library, so the fallback had nothing left to find — a miss here is
    /// a genuine absence, and going to the core for a second opinion would only
    /// add a round trip to say so.
    ///
    /// The one case that is NOT covered is a trashed item, which is why
    /// `findTrashedItem` exists separately.

    func findItem(byId id: UUID) -> LibraryItem? {
        loadedItems.first { $0.id == id }
    }

    func findItem(byCiteKey citeKey: String) -> LibraryItem? {
        loadedItems.first { $0.citeKey == citeKey }
    }

    func findItem(byStorageKey key: String) -> LibraryItem? {
        loadedItems.first { $0.storageKey == key }
    }

    func findItem(bySource source: String, sourceKey: String) -> LibraryItem? {
        loadedItems.first { $0.source == source && $0.sourceKey == sourceKey }
    }

    func findItem(byFileName fileName: String) -> LibraryItem? {
        loadedItems.first { item in item.attachments.contains { $0.fileName == fileName } }
    }

    func findItem(bySourceURL url: URL) -> LibraryItem? {
        loadedItems.first { $0.sourceURL == url }
    }

    /// Look in the bin. Separate because `findItem` deliberately does not.
    func findTrashedItem(byId id: UUID) -> LibraryItem? {
        loadedTrashedItems.first { $0.id == id }
    }

    func insertItem(_ record: ItemRecord, attachment: AttachmentRecord) -> LibraryItem? {
        do {
            var rec = record
            var attRec = attachment
            try database.dbQueue.write { db in
                try rec.insert(db)
                try attRec.insert(db)
            }
            // Auto-assign cite key for the new item
            let citeKeyService = CiteKeyService(database: database)
            try? citeKeyService.assignCiteKey(forItemId: rec.id)
            // Re-read to pick up the assigned cite key
            if let updated = try? database.dbQueue.read({ db in
                try ItemRecord.fetchOne(db, key: rec.id)
            }) {
                rec = updated
            }
            invalidate()
            let att = Attachment(record: attRec, itemStorageKey: rec.storageKey)
            let coverData = Self.loadCoverData(attachment: att)
            return LibraryItem(record: rec, attachments: [att], coverImageData: coverData)
        } catch {
            Log.error(Log.store, "insertItem failed: \(error)")
            return nil
        }
    }

    /// Delete an item permanently: its rows, and the files they pointed at.
    ///
    /// Two owners, in order. The core drops the row and everything the schema
    /// cascades from it — attachments, annotations, memberships, citations,
    /// conversation rows. The shell then deletes what lives on disk: the
    /// document's storage directory and each conversation's JSONL transcript.
    ///
    /// The conversation ids have to be read *before* the row goes, because the
    /// cascade takes them with it and the transcripts are named after them.
    func removeItem(_ item: LibraryItem) {
        removeItems([item])
    }

    func removeItems(_ items: [LibraryItem]) {
        guard !items.isEmpty else { return }
        Task {
            var transcripts: [UUID] = []
            for item in items {
                let conversations = await ConversationService()
                    .fetchSessions(forItemId: item.id.uuidString)
                transcripts.append(contentsOf: conversations.map(\.id))
            }

            await LibraryCatalog.remove(ids: items.map { $0.id.uuidString })

            // Files, now that nothing references them.
            for id in transcripts {
                try? FileManager.default.removeItem(at: CatalogDatabase.chatFileURL(sessionId: id))
                try? FileManager.default.removeItem(
                    at: CatalogDatabase.chatAttachmentDirectory(sessionId: id))
            }
            for item in items {
                try? FileManager.default.removeItem(
                    at: CatalogDatabase.documentDirectory(storageKey: item.storageKey))
            }

            await MainActor.run { self.invalidate() }
        }
    }

    /// These stay synchronous: every caller is a UI action, and the write is
    /// fire-and-forget followed by `invalidate()`, which reloads behind itself.
    /// Waiting on the round trip would stall a click to confirm something the
    /// interface has already shown.

    func markOpened(_ item: LibraryItem) {
        update(item, field: "lastOpenedAt", string: Date().iso8601String)
    }

    func updateTitle(_ item: LibraryItem, title: String) {
        update(item, field: "title", string: title)
    }

    func updateProcessingStatus(_ item: LibraryItem, status: ProcessingStatus) {
        update(item, field: "processingStatus", string: status.rawValue)
    }

    func updateLastPosition(_ item: LibraryItem, position: Double) {
        // Deliberately no invalidate: scroll position changes constantly and
        // reloading the library on every one would be absurd. Nothing displays
        // it, so the in-memory copy going stale costs nothing.
        Task { await LibraryCatalog.update(id: item.id.uuidString, field: "lastPosition", number: position) }
    }

    private func update(_ item: LibraryItem, field: String, string: String) {
        Task {
            await LibraryCatalog.update(id: item.id.uuidString, field: field, string: string)
            await MainActor.run { self.invalidate() }
        }
    }

    func updateCover(_ item: LibraryItem, imageData: Data) {
        guard let primary = item.primaryAttachment else { return }
        let coverURL = primary.coverURL
        do {
            try imageData.write(to: coverURL, options: .atomic)
            // Stamp web covers with the og-fetch scheme marker so the sweeper's one-time upgrade
            // doesn't needlessly re-generate a cover the current build just wrote.
            if item.contentType == .html || item.contentType == .link {
                try? Data().write(to: LibraryCoverSweeper.previewMarkerURL(for: primary), options: .atomic)
            }
            invalidate()
        } catch {
            Log.error(Log.store, "updateCover failed: \(error)")
        }
    }

    // MARK: - Merge Duplicates

    /// Merge duplicate items into a keeper. Transfers attachments, collections, property values,
    /// and notes from each duplicate to the keeper, then deletes the duplicates.
    func mergeItems(keeper: LibraryItem, duplicates: [LibraryItem]) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                for dup in duplicates {
                    guard dup.id != keeper.id else { continue }

                    // 1. Transfer non-primary attachments
                    try db.execute(
                        sql: "UPDATE attachments SET item_id = ?, is_primary = 0, updated_at = ? WHERE item_id = ?",
                        arguments: [keeper.id.uuidString, now, dup.id.uuidString]
                    )

                    // Move attachment files on disk
                    let fm = FileManager.default
                    let srcDir = CatalogDatabase.documentDirectory(storageKey: dup.storageKey)
                        .appendingPathComponent("attachments", isDirectory: true)
                    let dstDir = CatalogDatabase.documentDirectory(storageKey: keeper.storageKey)
                        .appendingPathComponent("attachments", isDirectory: true)
                    if fm.fileExists(atPath: srcDir.path) {
                        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                        let children = (try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                        for child in children {
                            let dest = dstDir.appendingPathComponent(child.lastPathComponent)
                            if !fm.fileExists(atPath: dest.path) {
                                try? fm.moveItem(at: child, to: dest)
                            }
                        }
                    }

                    // 2. Transfer collections (ignore duplicates via INSERT OR IGNORE)
                    let collRows = try Row.fetchAll(db,
                        sql: "SELECT collection_id FROM collection_items WHERE item_id = ?",
                        arguments: [dup.id.uuidString]
                    )
                    for row in collRows {
                        let collId: String = row["collection_id"]
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO collection_items (item_id, collection_id, created_at) VALUES (?, ?, ?)",
                            arguments: [keeper.id.uuidString, collId, now]
                        )
                    }

                    // 3. Transfer property values (skip if keeper already has same option)
                    let propRows = try Row.fetchAll(db,
                        sql: "SELECT property_id, option_id, text_value FROM item_property_values WHERE item_id = ?",
                        arguments: [dup.id.uuidString]
                    )
                    for row in propRows {
                        let propertyId: String = row["property_id"]
                        let optionId: String? = row["option_id"]
                        let textValue: String? = row["text_value"]

                        // Check if keeper already has this exact value
                        let existing: Int
                        if let oid = optionId {
                            existing = try Int.fetchOne(db,
                                sql: "SELECT COUNT(*) FROM item_property_values WHERE item_id = ? AND property_id = ? AND option_id = ?",
                                arguments: [keeper.id.uuidString, propertyId, oid]
                            ) ?? 0
                        } else {
                            existing = try Int.fetchOne(db,
                                sql: "SELECT COUNT(*) FROM item_property_values WHERE item_id = ? AND property_id = ? AND text_value = ?",
                                arguments: [keeper.id.uuidString, propertyId, textValue]
                            ) ?? 0
                        }

                        if existing == 0 {
                            try db.execute(
                                sql: "INSERT INTO item_property_values (id, item_id, property_id, option_id, text_value) VALUES (?, ?, ?, ?, ?)",
                                arguments: [UUID().uuidString, keeper.id.uuidString, propertyId, optionId, textValue]
                            )
                        }
                    }

                    // 4. Transfer conversations
                    try db.execute(
                        sql: "UPDATE conversations SET item_id = ?, updated_at = ? WHERE item_id = ?",
                        arguments: [keeper.id.uuidString, now, dup.id.uuidString]
                    )

                    // 5. Transfer annotations
                    try db.execute(
                        sql: "UPDATE annotations SET item_id = ?, updated_at = ? WHERE item_id = ?",
                        arguments: [keeper.id.uuidString, now, dup.id.uuidString]
                    )

                    // 6. Transfer citation (if keeper lacks one)
                    let keeperHasCitation = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM citations WHERE item_id = ?",
                        arguments: [keeper.id.uuidString]
                    ) ?? 0
                    if keeperHasCitation == 0 {
                        // Re-parent the dup's citation to the keeper
                        try db.execute(
                            sql: "UPDATE citations SET item_id = ?, updated_at = ? WHERE item_id = ?",
                            arguments: [keeper.id.uuidString, now, dup.id.uuidString]
                        )
                    }

                    // 7. Delete the duplicate item and its DB records (CASCADE handles remaining references).
                    //    Conversations, annotations, and attachments were already re-parented above,
                    //    so CASCADE only cleans up orphaned collection_items, property_values, and citations.
                    try db.execute(
                        sql: "DELETE FROM items WHERE id = ?",
                        arguments: [dup.id.uuidString]
                    )
                }
            }

            // Clean up files for deleted duplicates (DB records already gone)
            let fm = FileManager.default
            for dup in duplicates where dup.id != keeper.id {
                // Storage directory (attachments already moved to keeper above)
                let dir = CatalogDatabase.documentDirectory(storageKey: dup.storageKey)
                try? fm.removeItem(at: dir)
            }

            invalidate()
        } catch {
            Log.error(Log.store, "mergeItems failed: \(error)")
        }
    }

    // MARK: - Soft Delete (Bin)

    func fetchTrashedItems() throws -> [LibraryItem] {
        try database.dbQueue.read { db in
            let records = try ItemRecord.filter(ItemRecord.CodingKeys.deletedAt != nil).fetchAll(db)
            guard !records.isEmpty else { return [] }

            let trashedIds = records.map(\.id)

            let attachments = try AttachmentRecord
                .filter(trashedIds.contains(AttachmentRecord.CodingKeys.itemId))
                .fetchAll(db)
            let citations = try CitationRecord
                .filter(trashedIds.contains(CitationRecord.CodingKeys.itemId))
                .fetchAll(db)

            var itemAttachmentsMap: [String: [AttachmentRecord]] = [:]
            for att in attachments {
                itemAttachmentsMap[att.itemId, default: []].append(att)
            }

            var citationMap: [String: ReferenceMetadata] = [:]
            for record in citations {
                if let meta = ReferenceMetadata(jsonString: record.cslJson) {
                    citationMap[record.itemId] = meta
                }
            }

            return records.map { item in
                let attRecords = itemAttachmentsMap[item.id] ?? []
                let attachments = attRecords.map { Attachment(record: $0, itemStorageKey: item.storageKey) }
                let primary = attachments.first { $0.isPrimary } ?? attachments.first
                let coverData = primary.flatMap { Self.loadCoverData(attachment: $0) }
                let citation = citationMap[item.id]
                return LibraryItem(
                    record: item,
                    attachments: attachments,
                    coverImageData: coverData,
                    referenceMetadata: citation
                )
            }
        }
    }

    /// Bin operations.
    ///
    /// Singular and plural collapse into one call each: the core takes an id
    /// list, so `trashItem` is `trashItems` with one element and the four Swift
    /// methods that differed only in arity become two.

    func trashItem(_ item: LibraryItem) { trashItems([item]) }

    func trashItems(_ items: [LibraryItem]) {
        setTrashed(items, trashed: true)
    }

    func restoreItem(_ item: LibraryItem) { restoreItems([item]) }

    func restoreItems(_ items: [LibraryItem]) {
        setTrashed(items, trashed: false)
    }

    private func setTrashed(_ items: [LibraryItem], trashed: Bool) {
        guard !items.isEmpty else { return }
        let ids = items.map { $0.id.uuidString }
        Task {
            await LibraryCatalog.setTrashed(ids: ids, trashed: trashed)
            await MainActor.run { self.invalidate() }
        }
    }

    /// One call rather than a loop: the core deletes the batch in a
    /// transaction, so an interrupted empty cannot leave the bin half-cleared.
    func emptyBin() {
        removeItems(loadedTrashedItems)
    }

    // MARK: - Cover helpers

    private static func loadCoverData(attachment: Attachment) -> Data? {
        let url = attachment.coverURL
        return try? Data(contentsOf: url)
    }
}
