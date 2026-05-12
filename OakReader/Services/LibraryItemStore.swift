import Foundation
import AppKit
import GRDB

extension LibraryStore {
    // MARK: - Fetch

    func fetchAllItems() throws -> [LibraryItem] {
        try database.dbQueue.read { db in
            let records = try ItemRecord.fetchAll(db)
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
                let primary = attachments.first { $0.isPrimary } ?? attachments.first
                let coverData = primary.flatMap { Self.loadCoverData(attachment: $0) }
                let citation = citationMap[item.id]
                return LibraryItem(
                    record: item,
                    attachments: attachments,
                    propertyValues: propValues,
                    collections: collections,
                    coverImageData: coverData,
                    referenceMetadata: citation
                )
            }
        }
    }

    // MARK: - CRUD

    @discardableResult
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

    func findItem(byStorageKey key: String) -> LibraryItem? {
        items.first { $0.storageKey == key }
    }

    func findItem(bySource source: String, sourceKey: String) -> LibraryItem? {
        items.first { item in
            item.source == source && item.sourceKey == sourceKey
        }
    }

    func findItem(byFileName fileName: String) -> LibraryItem? {
        items.first { item in
            item.attachments.contains { $0.fileName == fileName }
        }
    }

    func removeItem(_ item: LibraryItem) {
        do {
            // Collect note IDs before deleting (cascade will remove DB records)
            let noteIds = try database.dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT id FROM notes WHERE item_id = ?", arguments: [item.id.uuidString])
                    .compactMap { UUID(uuidString: $0["id"] as String) }
            }
            // Collect conversation IDs
            let convIds = try database.dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT id FROM conversations WHERE item_id = ?", arguments: [item.id.uuidString])
                    .compactMap { UUID(uuidString: $0["id"] as String) }
            }

            // Delete from DB (cascades to notes, conversations records)
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [item.id.uuidString])
            }

            // Remove note files
            for noteId in noteIds {
                let url = CatalogDatabase.noteFileURL(noteId: noteId)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: CatalogDatabase.noteAttachmentDirectory(noteId: noteId))
            }
            // Remove chat files
            for convId in convIds {
                let url = CatalogDatabase.chatFileURL(sessionId: convId)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: CatalogDatabase.chatAttachmentDirectory(sessionId: convId))
            }
            // Remove storage directory (PDFs, covers, etc.)
            let dir = CatalogDatabase.documentDirectory(storageKey: item.storageKey)
            try? FileManager.default.removeItem(at: dir)

            // Clean up semantic chunks (GRDB side handled by CASCADE, explicit for safety)
            let itemIdForCleanup = item.id.uuidString
            Task { [weak self] in
                await self?.semanticIndexService?.removeChunks(forItemId: itemIdForCleanup)
            }

            invalidate()
        } catch {
            Log.error(Log.store, "removeItem failed: \(error)")
        }
    }

    func markOpened(_ item: LibraryItem) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE items SET last_opened_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [now, now, item.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "markOpened failed: \(error)")
        }
    }

    func updateTitle(_ item: LibraryItem, title: String) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE items SET title = ?, updated_at = ? WHERE id = ?",
                    arguments: [title, now, item.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "updateTitle failed: \(error)")
        }
    }

    func updateLastPosition(_ item: LibraryItem, position: Double) {
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE items SET last_position = ?, updated_at = ? WHERE id = ?",
                    arguments: [position, now, item.id.uuidString]
                )
            }
        } catch {
            Log.error(Log.store, "updateLastPosition failed: \(error)")
        }
    }

    func updateCover(_ item: LibraryItem, imageData: Data) {
        guard let primary = item.primaryAttachment else { return }
        let coverURL = primary.coverURL
        do {
            try imageData.write(to: coverURL, options: .atomic)
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

                    // 4. Transfer notes
                    try db.execute(
                        sql: "UPDATE notes SET item_id = ?, updated_at = ? WHERE item_id = ?",
                        arguments: [keeper.id.uuidString, now, dup.id.uuidString]
                    )

                    // 5. Transfer conversations
                    try db.execute(
                        sql: "UPDATE conversations SET item_id = ?, updated_at = ? WHERE item_id = ?",
                        arguments: [keeper.id.uuidString, now, dup.id.uuidString]
                    )

                    // 6. Transfer annotations
                    try db.execute(
                        sql: "UPDATE annotations SET item_id = ?, updated_at = ? WHERE item_id = ?",
                        arguments: [keeper.id.uuidString, now, dup.id.uuidString]
                    )

                    // 7. Transfer citation (if keeper lacks one)
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

                    // 8. Delete the duplicate item and its DB records (CASCADE handles remaining references).
                    //    Notes, conversations, annotations, and attachments were already re-parented above,
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

    // MARK: - Cover helpers

    private static func loadCoverData(attachment: Attachment) -> Data? {
        let url = attachment.coverURL
        return try? Data(contentsOf: url)
    }
}
