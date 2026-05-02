import AppKit
import Foundation
import GRDB
import PDFKit

@Observable
final class LibraryStore {
    let database: CatalogDatabase

    // Search & filter state
    var searchText: String = ""
    var currentSort: LibrarySortOrder = .dateAdded
    var sortAscending: Bool = false
    var selectedCollectionId: UUID? = SystemCollectionID.allItems
    var selectedTagOptionId: UUID?

    /// Resolved collection for the current selection.
    var selectedCollection: PDFCollection? {
        guard let id = selectedCollectionId else { return nil }
        return collections.first(where: { $0.id == id })
    }

    /// Select a collection and clear tag selection.
    func selectCollection(_ id: UUID?) {
        selectedCollectionId = id
        selectedTagOptionId = nil
    }

    /// Select a tag and clear collection selection.
    func selectTag(_ optionId: UUID?) {
        selectedTagOptionId = optionId
        selectedCollectionId = nil
    }

    /// The system "Tags" property definition.
    var tagsProperty: PropertyDefinition? {
        properties.first { $0.name == "Tags" && $0.isSystem }
    }

    /// Returns tag options with their item counts, sorted by count descending.
    func tagOptionsWithCounts() -> [(option: PropertyOption, count: Int)] {
        guard let tagsProp = tagsProperty else { return [] }
        let allItems = items
        return tagsProp.options.map { option in
            let count = allItems.filter { item in
                item.propertyValues.contains { $0.option?.id == option.id }
            }.count
            return (option: option, count: count)
        }.sorted { $0.count > $1.count }
    }

    /// Which system smart collections are hidden in the sidebar (synced to Preferences).
    var hiddenSystemCollectionIds: Set<UUID> = Preferences.shared.hiddenSystemCollectionIds {
        didSet { Preferences.shared.hiddenSystemCollectionIds = hiddenSystemCollectionIds }
    }

    // Observation trigger — bump this to force computed properties to re-evaluate
    private(set) var revision: Int = 0

    /// Notify the store that data has changed externally.
    func invalidate() {
        revision += 1
    }

    init(database: CatalogDatabase) {
        self.database = database
    }

    // MARK: - Library Items

    var items: [LibraryItem] {
        _ = revision
        return (try? fetchAllItems()) ?? []
    }

    var inboxCount: Int {
        _ = revision
        return items.filter { $0.isInbox }.count
    }

    var filteredItems: [LibraryItem] {
        var results = items

        // Apply tag filter (mutually exclusive with collection)
        if let tagId = selectedTagOptionId {
            results = results.filter { item in
                item.propertyValues.contains { $0.option?.id == tagId }
            }
        }
        // Apply collection filter (smart or traditional)
        else if let collection = selectedCollection {
            if collection.isSmart, let rules = collection.filterRules {
                results = results.filter { evaluateRules(rules, against: $0) }
            } else if !collection.isSmart {
                results = results.filter { $0.collections.contains(where: { $0.id == collection.id }) }
            }
            // isSmart with nil rules → show all (e.g. "All Items")
        }

        // Apply search
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
            case .dateOpened: cmp = (a.lastOpenedAt ?? .distantPast) < (b.lastOpenedAt ?? .distantPast)
            case .title:      cmp = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .author:     cmp = a.author.localizedCaseInsensitiveCompare(b.author) == .orderedAscending
            case .fileSize:   cmp = a.fileSize < b.fileSize
            }
            return sortAscending ? cmp : !cmp
        }

        return results
    }

    // MARK: - Rule Evaluation

    private func evaluateRules(_ rules: FilterRuleSet, against item: LibraryItem) -> Bool {
        if rules.conditions.isEmpty { return true }

        switch rules.match {
        case .all:
            return rules.conditions.allSatisfy { evaluateCondition($0, against: item) }
        case .any:
            return rules.conditions.contains { evaluateCondition($0, against: item) }
        }
    }

    private func evaluateCondition(_ condition: FilterCondition, against item: LibraryItem) -> Bool {
        switch condition.field {
        case .isInbox:
            return matchBool(item.isInbox, op: condition.op, value: condition.value)
        case .isFavorite:
            return matchBool(item.isFavorite, op: condition.op, value: condition.value)
        case .itemType:
            // Match if any attachment has the specified type
            let hasType = item.attachments.contains { $0.attachmentType.rawValue == condition.value }
            switch condition.op {
            case .eq: return hasType
            case .neq: return !hasType
            default: return matchString(item.itemType.rawValue, op: condition.op, value: condition.value)
            }
        case .createdAt:
            return matchDate(item.dateAdded, op: condition.op, value: condition.value)
        case .title:
            return matchString(item.title, op: condition.op, value: condition.value)
        case .author:
            return matchString(item.author, op: condition.op, value: condition.value)
        case .property:
            return matchProperty(item, condition: condition)
        }
    }

    private func matchBool(_ actual: Bool, op: FilterOperator, value: String) -> Bool {
        let expected = (value == "true")
        switch op {
        case .eq: return actual == expected
        case .neq: return actual != expected
        default: return false
        }
    }

    private func matchString(_ actual: String, op: FilterOperator, value: String) -> Bool {
        switch op {
        case .eq: return actual.caseInsensitiveCompare(value) == .orderedSame
        case .neq: return actual.caseInsensitiveCompare(value) != .orderedSame
        case .contains: return actual.localizedCaseInsensitiveContains(value)
        default: return false
        }
    }

    private func matchDate(_ actual: Date, op: FilterOperator, value: String) -> Bool {
        switch op {
        case .withinDays:
            guard let days = Int(value) else { return false }
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            return actual >= cutoff
        default:
            return false
        }
    }

    private func matchProperty(_ item: LibraryItem, condition: FilterCondition) -> Bool {
        guard let propertyId = condition.propertyId else { return false }
        let values = item.propertyValues.filter { $0.propertyId.uuidString == propertyId }

        switch condition.op {
        case .hasOption:
            return values.contains { $0.option?.name.caseInsensitiveCompare(condition.value) == .orderedSame }
        case .eq:
            return values.contains { ($0.textValue ?? $0.option?.name ?? "").caseInsensitiveCompare(condition.value) == .orderedSame }
        case .contains:
            return values.contains { ($0.textValue ?? $0.option?.name ?? "").localizedCaseInsensitiveContains(condition.value) }
        default:
            return false
        }
    }

    /// Count items matching a smart collection's rules.
    func smartCollectionItemCount(for collection: PDFCollection) -> Int {
        guard collection.isSmart, let rules = collection.filterRules else {
            return collection.itemCount
        }
        return items.filter { evaluateRules(rules, against: $0) }.count
    }

    // MARK: - Fetch

    private func fetchAllItems() throws -> [LibraryItem] {
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
                return LibraryItem(record: item, attachments: attachments, propertyValues: propValues, collections: collections, coverImageData: coverData, referenceMetadata: citation)
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
            revision += 1
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

    func findItem(byFileName fileName: String) -> LibraryItem? {
        items.first { item in
            item.attachments.contains { $0.fileName == fileName }
        }
    }

    func removeItem(_ item: LibraryItem) {
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [item.id.uuidString])
            }
            // Remove storage directory
            let dir = CatalogDatabase.documentDirectory(storageKey: item.storageKey)
            try? FileManager.default.removeItem(at: dir)
            revision += 1
        } catch {
            Log.error(Log.store, "removeItem failed: \(error)")
        }
    }

    func toggleFavorite(_ item: LibraryItem) {
        let newValue = !item.isFavorite
        let now = Date().iso8601String
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE items SET is_favorite = ?, updated_at = ? WHERE id = ?",
                    arguments: [newValue, now, item.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "toggleFavorite failed: \(error)")
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
            revision += 1
        } catch {
            Log.error(Log.store, "markOpened failed: \(error)")
        }
    }

    func updateCover(_ item: LibraryItem, imageData: Data) {
        guard let primary = item.primaryAttachment else { return }
        let coverURL = primary.coverURL
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

    /// System smart collections (Inbox, All Items, etc.).
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

    private func fetchAllCollections() throws -> [PDFCollection] {
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
    func createCollection(name: String, icon: String = "folder.fill") -> PDFCollection {
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
            revision += 1
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
            revision += 1
        } catch {
            Log.error(Log.store, "updateSmartCollectionRules failed: \(error)")
        }
    }

    @discardableResult
    func createSubcollection(name: String, icon: String = "folder.fill", parent: PDFCollection) -> PDFCollection {
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
        guard !collection.isSystem else { return }
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [collection.id.uuidString])
            }
            if selectedCollectionId == collection.id {
                selectedCollectionId = SystemCollectionID.allItems
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
                // Archive from inbox when organized into a collection
                try db.execute(
                    sql: "UPDATE items SET is_inbox = 0, updated_at = ? WHERE id = ?",
                    arguments: [now, item.id.uuidString]
                )
            }
            revision += 1
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

            let item: LibraryItem?
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

        selectedCollectionId = collection.id
        return count
    }

    // MARK: - Properties

    var properties: [PropertyDefinition] {
        _ = revision
        return (try? fetchAllProperties()) ?? []
    }

    private func fetchAllProperties() throws -> [PropertyDefinition] {
        try database.dbQueue.read { db in
            let propRecords = try PropertyRecord.order(PropertyRecord.CodingKeys.position).fetchAll(db)
            let optionRecords = try PropertyOptionRecord.order(PropertyOptionRecord.CodingKeys.position).fetchAll(db)

            var optionsByProperty: [String: [PropertyOption]] = [:]
            for opt in optionRecords {
                optionsByProperty[opt.propertyId, default: []].append(PropertyOption(record: opt))
            }

            return propRecords.map { prop in
                PropertyDefinition(record: prop, options: optionsByProperty[prop.id] ?? [])
            }
        }
    }

    @discardableResult
    func createProperty(name: String, type: PropertyType, icon: String = "tag") -> PropertyDefinition? {
        let id = UUID().uuidString
        let record = PropertyRecord(
            id: id,
            name: name,
            type: type.rawValue,
            icon: icon,
            position: properties.count,
            isSystem: false
        )
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.insert(db)
            }
            revision += 1
            return PropertyDefinition(record: record)
        } catch {
            Log.error(Log.store, "createProperty failed: \(error)")
            return nil
        }
    }

    func deleteProperty(_ property: PropertyDefinition) {
        guard !property.isSystem else { return }
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM properties WHERE id = ?", arguments: [property.id.uuidString])
            }
            revision += 1
        } catch {
            Log.error(Log.store, "deleteProperty failed: \(error)")
        }
    }

    @discardableResult
    func addPropertyOption(propertyId: UUID, name: String, colorHex: String) -> PropertyOption? {
        let optId = UUID().uuidString
        let record = PropertyOptionRecord(
            id: optId,
            propertyId: propertyId.uuidString,
            name: name,
            colorHex: colorHex,
            position: 0  // Will be appended at end
        )
        do {
            try database.dbQueue.write { db in
                // Get next position
                let maxPos = try Int.fetchOne(db, sql: """
                    SELECT MAX(position) FROM property_options WHERE property_id = ?
                """, arguments: [propertyId.uuidString]) ?? -1
                var r = record
                r.position = maxPos + 1
                try r.insert(db)
            }
            revision += 1
            return PropertyOption(record: record)
        } catch {
            Log.error(Log.store, "addPropertyOption failed: \(error)")
            return nil
        }
    }

    func removePropertyOption(_ option: PropertyOption) {
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM property_options WHERE id = ?", arguments: [option.id.uuidString])
            }
            revision += 1
        } catch {
            Log.error(Log.store, "removePropertyOption failed: \(error)")
        }
    }

    func renamePropertyOption(_ option: PropertyOption, to newName: String) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE property_options SET name = ? WHERE id = ?",
                    arguments: [newName, option.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "renamePropertyOption failed: \(error)")
        }
    }

    func updatePropertyOptionColor(_ option: PropertyOption, colorHex: String) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE property_options SET color_hex = ? WHERE id = ?",
                    arguments: [colorHex, option.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "updatePropertyOptionColor failed: \(error)")
        }
    }

    /// Set a select-type property value (adds option_id to item_property_values).
    /// For multi_select: adds if not already present.
    /// For single_select: replaces existing value.
    func setItemSelectValue(item: LibraryItem, property: PropertyDefinition, option: PropertyOption) {
        do {
            try database.dbQueue.write { db in
                if property.type == .singleSelect {
                    // Remove existing value for this property
                    try db.execute(
                        sql: "DELETE FROM item_property_values WHERE item_id = ? AND property_id = ?",
                        arguments: [item.id.uuidString, property.id.uuidString]
                    )
                } else {
                    // multi_select: check if already assigned
                    let exists = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM item_property_values
                        WHERE item_id = ? AND property_id = ? AND option_id = ?
                    """, arguments: [item.id.uuidString, property.id.uuidString, option.id.uuidString]) ?? 0
                    if exists > 0 { return }
                }

                var record = ItemPropertyValueRecord(
                    id: UUID().uuidString,
                    itemId: item.id.uuidString,
                    propertyId: property.id.uuidString,
                    optionId: option.id.uuidString,
                    textValue: nil
                )
                try record.insert(db)
            }
            revision += 1
        } catch {
            Log.error(Log.store, "setItemSelectValue failed: \(error)")
        }
    }

    /// Remove a select-type property value (removes the option from the item).
    func removeItemSelectValue(item: LibraryItem, property: PropertyDefinition, option: PropertyOption) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM item_property_values WHERE item_id = ? AND property_id = ? AND option_id = ?",
                    arguments: [item.id.uuidString, property.id.uuidString, option.id.uuidString]
                )
            }
            revision += 1
        } catch {
            Log.error(Log.store, "removeItemSelectValue failed: \(error)")
        }
    }

    /// Set a text/number property value.
    func setItemTextValue(item: LibraryItem, property: PropertyDefinition, value: String) {
        do {
            try database.dbQueue.write { db in
                // Remove existing
                try db.execute(
                    sql: "DELETE FROM item_property_values WHERE item_id = ? AND property_id = ?",
                    arguments: [item.id.uuidString, property.id.uuidString]
                )
                if !value.isEmpty {
                    var record = ItemPropertyValueRecord(
                        id: UUID().uuidString,
                        itemId: item.id.uuidString,
                        propertyId: property.id.uuidString,
                        optionId: nil,
                        textValue: value
                    )
                    try record.insert(db)
                }
            }
            revision += 1
        } catch {
            Log.error(Log.store, "setItemTextValue failed: \(error)")
        }
    }

    // MARK: - Citation Export

    /// Copy a formatted citation to the pasteboard.
    func copyCitation(_ item: LibraryItem, style: CitationStyle) {
        guard let csl = item.referenceMetadata?.cslItem else { return }
        let text: String
        switch style {
        case .apa: text = CitationFormatter.toAPA(csl: csl)
        case .mla: text = CitationFormatter.toMLA(csl: csl)
        case .chicago: text = CitationFormatter.toChicago(csl: csl)
        case .bibtex: text = CitationFormatter.toBibTeX(csl: csl)
        case .ris: text = CitationFormatter.toRIS(csl: csl)
        case .cslJson: text = CitationFormatter.toCSLJSON(csl: csl)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Export multiple items as BibTeX.
    func exportBibTeX(items: [LibraryItem]) -> String {
        items.compactMap { $0.referenceMetadata?.cslItem }
            .map { CitationFormatter.toBibTeX(csl: $0) }
            .joined(separator: "\n\n")
    }

    /// Export multiple items as RIS.
    func exportRIS(items: [LibraryItem]) -> String {
        items.compactMap { $0.referenceMetadata?.cslItem }
            .map { CitationFormatter.toRIS(csl: $0) }
            .joined(separator: "\n")
    }

    /// Export multiple items as CSL JSON array.
    func exportCSLJSON(items: [LibraryItem]) -> String {
        let cslItems = items.compactMap { $0.referenceMetadata?.cslItem }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cslItems),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    // MARK: - Cover helpers

    private static func loadCoverData(attachment: Attachment) -> Data? {
        let url = attachment.coverURL
        return try? Data(contentsOf: url)
    }
}
