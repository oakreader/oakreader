import Foundation
import PDFKit
import SQLite3

// MARK: - Progress & Result Types

enum ZoteroMigrationPhase: String {
    case reading = "Reading Zotero database..."
    case collections = "Creating collections..."
    case items = "Importing items..."
    case attachments = "Copying files..."
    case tags = "Importing tags..."
    case collectionAssignments = "Assigning items to collections..."
    case done = "Done"
}

struct ZoteroMigrationProgress {
    var phase: ZoteroMigrationPhase = .reading
    var current: Int = 0
    var total: Int = 0
    var currentItemTitle: String = ""
}

struct ZoteroMigrationResult {
    var itemCount: Int = 0
    var pdfCount: Int = 0
    var htmlCount: Int = 0
    var collectionCount: Int = 0
    var tagCount: Int = 0
    var errors: [String] = []
    var skippedDuplicates: Int = 0
}

// MARK: - Intermediate Structs

private struct ZoteroItem {
    let itemID: Int
    let key: String
    let typeName: String
}

private struct ZoteroField {
    let itemID: Int
    let fieldName: String
    let value: String
}

private struct ZoteroCreator {
    let itemID: Int
    let creatorType: String
    let firstName: String
    let lastName: String
    let orderIndex: Int
}

private struct ZoteroCollection {
    let collectionID: Int
    let key: String
    let name: String
    let parentCollectionID: Int?
}

private struct ZoteroCollectionItem {
    let collectionID: Int
    let itemID: Int
}

private struct ZoteroTag {
    let tagID: Int
    let name: String
}

private struct ZoteroItemTag {
    let itemID: Int
    let tagID: Int
}

private struct ZoteroAttachment {
    let itemID: Int
    let parentItemID: Int?
    let key: String
    let path: String?
    let contentType: String?
}

// MARK: - SQLite Reader

/// Reads Zotero's SQLite database in read-only mode. The original database is never modified.
private class ZoteroSQLiteReader {
    private var db: OpaquePointer?

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
    }

    func close() {
        sqlite3_close(db)
    }

    // MARK: - Fetch Methods

    func fetchItems() -> [ZoteroItem] {
        let sql = """
            SELECT i.itemID, i.key, it.typeName
            FROM items i
            JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
            WHERE it.typeName NOT IN ('attachment', 'note', 'annotation')
              AND i.itemID NOT IN (SELECT itemID FROM deletedItems)
        """
        return query(sql) { stmt in
            ZoteroItem(
                itemID: Int(sqlite3_column_int(stmt, 0)),
                key: stringCol(stmt, 1) ?? "",
                typeName: stringCol(stmt, 2) ?? ""
            )
        }
    }

    func fetchItemFields() -> [ZoteroField] {
        let sql = """
            SELECT id.itemID, f.fieldName, idv.value
            FROM itemData id
            JOIN fields f ON id.fieldID = f.fieldID
            JOIN itemDataValues idv ON id.valueID = idv.valueID
        """
        return query(sql) { stmt in
            ZoteroField(
                itemID: Int(sqlite3_column_int(stmt, 0)),
                fieldName: stringCol(stmt, 1) ?? "",
                value: stringCol(stmt, 2) ?? ""
            )
        }
    }

    func fetchCreators() -> [ZoteroCreator] {
        let sql = """
            SELECT ic.itemID, ct.creatorType, c.firstName, c.lastName, ic.orderIndex
            FROM itemCreators ic
            JOIN creators c ON ic.creatorID = c.creatorID
            JOIN creatorTypes ct ON ic.creatorTypeID = ct.creatorTypeID
            ORDER BY ic.itemID, ic.orderIndex
        """
        return query(sql) { stmt in
            ZoteroCreator(
                itemID: Int(sqlite3_column_int(stmt, 0)),
                creatorType: stringCol(stmt, 1) ?? "",
                firstName: stringCol(stmt, 2) ?? "",
                lastName: stringCol(stmt, 3) ?? "",
                orderIndex: Int(sqlite3_column_int(stmt, 4))
            )
        }
    }

    func fetchCollections() -> [ZoteroCollection] {
        let sql = """
            SELECT c.collectionID, c.key, c.collectionName, c.parentCollectionID
            FROM collections c
            WHERE c.collectionID NOT IN (SELECT collectionID FROM deletedCollections)
        """
        return query(sql) { stmt in
            let parentID = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 3))
            return ZoteroCollection(
                collectionID: Int(sqlite3_column_int(stmt, 0)),
                key: stringCol(stmt, 1) ?? "",
                name: stringCol(stmt, 2) ?? "",
                parentCollectionID: parentID
            )
        }
    }

    func fetchCollectionItems() -> [ZoteroCollectionItem] {
        let sql = "SELECT collectionID, itemID FROM collectionItems"
        return query(sql) { stmt in
            ZoteroCollectionItem(
                collectionID: Int(sqlite3_column_int(stmt, 0)),
                itemID: Int(sqlite3_column_int(stmt, 1))
            )
        }
    }

    func fetchTags() -> [ZoteroTag] {
        let sql = "SELECT tagID, name FROM tags"
        return query(sql) { stmt in
            ZoteroTag(
                tagID: Int(sqlite3_column_int(stmt, 0)),
                name: stringCol(stmt, 1) ?? ""
            )
        }
    }

    func fetchItemTags() -> [ZoteroItemTag] {
        let sql = "SELECT itemID, tagID FROM itemTags"
        return query(sql) { stmt in
            ZoteroItemTag(
                itemID: Int(sqlite3_column_int(stmt, 0)),
                tagID: Int(sqlite3_column_int(stmt, 1))
            )
        }
    }

    func fetchAttachments() -> [ZoteroAttachment] {
        let sql = """
            SELECT ia.itemID, ia.parentItemID, i.key, ia.path, ia.contentType
            FROM itemAttachments ia
            JOIN items i ON ia.itemID = i.itemID
            WHERE ia.contentType IN ('application/pdf', 'text/html', 'application/xhtml+xml')
              AND ia.parentItemID IS NOT NULL
              AND i.itemID NOT IN (SELECT itemID FROM deletedItems)
        """
        return query(sql) { stmt in
            let parentID = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 1))
            return ZoteroAttachment(
                itemID: Int(sqlite3_column_int(stmt, 0)),
                parentItemID: parentID,
                key: stringCol(stmt, 2) ?? "",
                path: stringCol(stmt, 3),
                contentType: stringCol(stmt, 4)
            )
        }
    }

    // MARK: - Helpers

    private func query<T>(_ sql: String, map: (OpaquePointer?) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            Log.error(Log.zotero, "SQL prepare failed: \(errMsg) — \(sql.prefix(80))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(map(stmt))
        }
        return results
    }

    private func stringCol(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }
}

// MARK: - Migration Service

final class ZoteroMigrationService {
    private let store: LibraryStore
    private let coverService: LibraryCoverService
    private let referenceService: ReferenceService

    init(store: LibraryStore, coverService: LibraryCoverService, referenceService: ReferenceService) {
        self.store = store
        self.coverService = coverService
        self.referenceService = referenceService
    }

    // MARK: - Detection

    /// Auto-detect the Zotero data directory by checking the default path.
    func detectZoteroDataDirectory() -> URL? {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Zotero")
        let dbPath = defaultDir.appendingPathComponent("zotero.sqlite")
        if FileManager.default.fileExists(atPath: dbPath.path) {
            return defaultDir
        }
        return nil
    }

    // MARK: - Run Migration

    func run(
        dataDirectory: URL,
        progress: @escaping (ZoteroMigrationProgress) -> Void
    ) async -> ZoteroMigrationResult {
        var result = ZoteroMigrationResult()
        var prog = ZoteroMigrationProgress()

        let dbPath = dataDirectory.appendingPathComponent("zotero.sqlite").path

        // Phase 1: Read Zotero database (read-only — the original data is never modified)
        prog.phase = .reading
        progress(prog)

        guard let reader = ZoteroSQLiteReader(path: dbPath) else {
            result.errors.append("Failed to open Zotero database at \(dbPath)")
            return result
        }
        defer { reader.close() }

        let zItems = reader.fetchItems()
        let zFields = reader.fetchItemFields()
        let zCreators = reader.fetchCreators()
        let zCollections = reader.fetchCollections()
        let zCollectionItems = reader.fetchCollectionItems()
        let zTags = reader.fetchTags()
        let zItemTags = reader.fetchItemTags()
        let zAttachments = reader.fetchAttachments()

        Log.info(Log.zotero, "Read \(zItems.count) items, \(zCollections.count) collections, \(zTags.count) tags, \(zAttachments.count) attachments")

        // Build lookup maps
        let fieldsByItem = Dictionary(grouping: zFields, by: \.itemID)
        let creatorsByItem = Dictionary(grouping: zCreators, by: \.itemID)
        let attachmentsByParent = Dictionary(grouping: zAttachments, by: \.parentItemID)
        let tagMap = Dictionary(uniqueKeysWithValues: zTags.map { ($0.tagID, $0.name) })
        let tagsByItem = Dictionary(grouping: zItemTags, by: \.itemID)
        let collectionItemsByCollection = Dictionary(grouping: zCollectionItems, by: \.collectionID)

        // Phase 2: Create collections
        prog.phase = .collections
        prog.total = zCollections.count
        prog.current = 0
        progress(prog)

        // Map Zotero collectionID -> OakReader PDFCollection
        var collectionMap: [Int: PDFCollection] = [:]

        // Sort to process parents before children
        let sortedCollections = topologicalSort(zCollections)
        for zColl in sortedCollections {
            prog.current += 1
            prog.currentItemTitle = zColl.name
            progress(prog)

            // Reuse existing collection if already imported from Zotero
            if let existing = store.findCollection(bySource: "zotero", sourceKey: zColl.key) {
                collectionMap[zColl.collectionID] = existing
                continue
            }

            if let parentID = zColl.parentCollectionID, let parentColl = collectionMap[parentID] {
                let oakColl = store.createSubcollection(
                    name: zColl.name, icon: "folder.fill", parent: parentColl,
                    source: "zotero", sourceKey: zColl.key
                )
                collectionMap[zColl.collectionID] = oakColl
            } else {
                let oakColl = store.createCollection(
                    name: zColl.name, icon: "folder.fill",
                    source: "zotero", sourceKey: zColl.key
                )
                collectionMap[zColl.collectionID] = oakColl
            }
            result.collectionCount += 1
        }

        // Phase 3: Create items
        prog.phase = .items
        prog.total = zItems.count
        prog.current = 0
        progress(prog)

        // Map Zotero itemID -> OakReader item ID (as UUID string)
        var itemMap: [Int: String] = [:]
        // Map Zotero itemID -> OakReader LibraryItem
        var libraryItemMap: [Int: LibraryItem] = [:]

        for zItem in zItems {
            prog.current += 1
            let fields = fieldsByItem[zItem.itemID] ?? []
            let title = fields.first(where: { $0.fieldName == "title" })?.value ?? "Untitled"
            prog.currentItemTitle = title
            progress(prog)

            // Skip items that were already imported from Zotero
            if itemExistsForSource("zotero", key: zItem.key) {
                result.skippedDuplicates += 1
                if let existingItem = store.findItem(bySource: "zotero", sourceKey: zItem.key) {
                    itemMap[zItem.itemID] = existingItem.id.uuidString
                    libraryItemMap[zItem.itemID] = existingItem
                }
                continue
            }

            // Build CSL item
            let cslType = ZoteroFieldMapping.itemTypeToCSL[zItem.typeName] ?? "document"
            var cslItem = CSLItem(type: cslType)

            var extraText: String?
            for field in fields {
                // Route Zotero "extra" to items.extra column, not CSL note
                if field.fieldName == "extra" {
                    extraText = field.value
                    continue
                }
                guard let cslField = ZoteroFieldMapping.fieldToCSL[field.fieldName] else { continue }
                switch cslField {
                case "note":
                    // Append note-mapped fields (e.g., rights)
                    if let existing = cslItem.note, !existing.isEmpty {
                        cslItem.note = existing + "\n" + field.value
                    } else {
                        cslItem.note = field.value
                    }
                case "issued":
                    cslItem.issued = parseZoteroDate(field.value)
                case "accessed":
                    cslItem.accessed = parseZoteroDate(field.value)
                default:
                    // All other fields: set by CSL JSON key directly
                    cslItem[jsonKey: cslField] = field.value
                }
            }

            // Merge extra field CSL pairs into CSL item (only fills empty fields)
            if let extra = extraText {
                ReferenceService.mergeExtraFields(extra, into: &cslItem)
            }

            // Creators — route to specific CSL role arrays
            let creators = creatorsByItem[zItem.itemID] ?? []
            var creatorsByRole: [String: [CSLName]] = [:]

            for creator in creators.sorted(by: { $0.orderIndex < $1.orderIndex }) {
                let name = CSLName(family: creator.lastName, given: creator.firstName)
                let cslRole = ZoteroFieldMapping.creatorTypeToCSL[creator.creatorType] ?? "author"
                creatorsByRole[cslRole, default: []].append(name)
            }

            for (role, names) in creatorsByRole {
                cslItem.setCreators(role: role, names: names)
            }

            // Build author display string
            let authorDisplay = (cslItem.author ?? [])
                .map { $0.displayString }
                .joined(separator: ", ")

            // Create OakReader item
            let docId = UUID()
            let itemStorageKey = CatalogDatabase.generateStorageKey()
            let attStorageKey = CatalogDatabase.generateStorageKey()
            let now = Date().iso8601String
            let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
            let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)

            do {
                try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
            } catch {
                Log.error(Log.zotero, "Failed to create directories for item '\(title)': \(error)")
                result.errors.append("Directory creation failed: \(title)")
                continue
            }

            // Detect video sites (YouTube, Bilibili) by URL before looking at attachments
            let isVideo = cslItem.URL.map { Self.isVideoURL($0) } ?? false

            // Find attachment — prefer PDF over HTML when multiple exist
            let allAttachments = (attachmentsByParent[zItem.itemID] ?? [])
                .sorted { a, _ in a.contentType == "application/pdf" ? true : false }
            let primaryAtt = allAttachments.first
            var contentType: ContentType = isVideo ? .link : oakItemType(for: primaryAtt?.contentType)
            var attFileName = isVideo ? "metadata.json" : (contentType == .pdf ? "document.pdf" : "index.html")
            var attFileSize: Int64 = 0
            var attPageCount = 0
            var fileCopied = false

            if isVideo {
                // Write metadata.json for YouTube items
                let publishedAt: String? = cslItem.issued.flatMap { date in
                    guard let y = date.year else { return date.raw }
                    let m = date.month ?? 1
                    let d = date.day ?? 1
                    return String(format: "%04d-%02d-%02dT00:00:00Z", y, m, d)
                }
                let metadata = MediaMetadata(
                    title: cslItem.title ?? title,
                    author: authorDisplay,
                    sourceURL: URL(string: cslItem.URL!)!,
                    duration: nil,
                    thumbnailURL: nil,
                    publishedAt: publishedAt,
                    description: cslItem.abstract,
                    embedType: "youtube"
                )
                if let encoded = try? JSONEncoder().encode(metadata) {
                    try? encoded.write(to: attDir.appendingPathComponent("metadata.json"), options: .atomic)
                }
            } else if let att = primaryAtt {
                let sourceURL = resolveAttachmentPath(att, dataDirectory: dataDirectory)
                if let srcURL = sourceURL, FileManager.default.fileExists(atPath: srcURL.path) {
                    attFileName = srcURL.lastPathComponent
                    let destURL = CatalogDatabase.attachmentFileURL(
                        itemStorageKey: itemStorageKey,
                        attachmentStorageKey: attStorageKey,
                        fileName: attFileName
                    )
                    do {
                        try FileManager.default.copyItem(at: srcURL, to: destURL)
                        fileCopied = true

                        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
                           let size = attrs[.size] as? Int64 {
                            attFileSize = size
                        }

                        if contentType == .pdf {
                            if let pdfDoc = PDFDocument(url: destURL) {
                                attPageCount = pdfDoc.pageCount
                            }
                        } else {
                            attPageCount = 1
                            // Copy sibling files (images, CSS, JS) for HTML documents
                            copyDirectoryContents(
                                from: srcURL.deletingLastPathComponent(),
                                to: attDir,
                                excluding: attFileName
                            )
                        }
                    } catch {
                        Log.error(Log.zotero, "Failed to copy attachment for '\(title)': \(error)")
                        result.errors.append("File copy failed: \(title)")
                    }
                }
            }

            // If no file was copied and item has a URL, treat as a linked web bookmark
            if !fileCopied && !isVideo, let urlString = cslItem.URL, let url = URL(string: urlString) {
                contentType = .link
                attFileName = "metadata.json"
                let metadata = MediaMetadata(
                    title: cslItem.title ?? title,
                    author: authorDisplay,
                    sourceURL: url,
                    duration: nil,
                    thumbnailURL: nil,
                    publishedAt: nil,
                    description: cslItem.abstract,
                    embedType: "link"
                )
                if let encoded = try? JSONEncoder().encode(metadata) {
                    try? encoded.write(to: attDir.appendingPathComponent("metadata.json"), options: .atomic)
                }
                let embedHTML = ImportService.generateLinkEmbedHTML(metadata: metadata)
                try? embedHTML.write(to: attDir.appendingPathComponent("embed.html"), atomically: true, encoding: .utf8)
            }

            let linkMode: LinkMode
            switch contentType {
            case .link: linkMode = .linkedURL
            case .html:         linkMode = .importedURL
            default:            linkMode = .importedFile
            }

            let itemRecord = ItemRecord(
                id: docId.uuidString,
                userId: localUserId,
                storageKey: itemStorageKey,
                title: cslItem.title ?? title,
                author: authorDisplay,
                lastOpenedAt: nil,
                syncStatus: SyncStatus.local.rawValue,
                createdAt: now,
                updatedAt: now,
                source: "zotero",
                sourceKey: zItem.key,
                extra: extraText
            )

            let attRecord = AttachmentRecord(
                id: UUID().uuidString,
                itemId: docId.uuidString,
                storageKey: attStorageKey,
                fileName: attFileName,
                contentType: contentType.rawValue,
                linkMode: linkMode.rawValue,
                sourceURL: cslItem.URL,
                fileSize: attFileSize,
                pageCount: attPageCount,
                isPrimary: true,
                createdAt: now,
                updatedAt: now
            )

            guard let libraryItem = store.insertItem(itemRecord, attachment: attRecord) else {
                Log.error(Log.zotero, "Failed to insert item '\(title)' into database")
                result.errors.append("DB insert failed: \(title)")
                try? FileManager.default.removeItem(at: docDir)
                continue
            }

            // Save citation metadata (with extra for PMID/arXiv extraction)
            do {
                try referenceService.saveMetadata(cslItem, forItemId: docId.uuidString, extra: extraText)
            } catch {
                Log.error(Log.zotero, "Failed to save citation for '\(title)': \(error)")
            }

            // Enrich HTML document metadata from HTML meta tags
            if contentType == .html && fileCopied {
                let destURL = CatalogDatabase.attachmentFileURL(
                    itemStorageKey: itemStorageKey,
                    attachmentStorageKey: attStorageKey,
                    fileName: attFileName
                )
                enrichHTMLMetadata(htmlURL: destURL, itemId: docId.uuidString)
            }

            itemMap[zItem.itemID] = docId.uuidString
            libraryItemMap[zItem.itemID] = libraryItem
            result.itemCount += 1
            if fileCopied {
                switch contentType {
                case .pdf: result.pdfCount += 1
                case .html: result.htmlCount += 1
                default: break
                }
            }

            // Generate cover asynchronously for copied files
            if fileCopied {
                let destURL = CatalogDatabase.attachmentFileURL(
                    itemStorageKey: itemStorageKey,
                    attachmentStorageKey: attStorageKey,
                    fileName: attFileName
                )
                let capturedItem = libraryItem
                let capturedType = contentType
                Task {
                    let coverData: Data?
                    switch capturedType {
                    case .html:
                        coverData = await coverService.generateHTMLCover(for: destURL, sourceURL: capturedItem.sourceURL)
                    default:
                        coverData = await coverService.generateCover(for: destURL)
                    }
                    if let coverData {
                        await MainActor.run {
                            store.updateCover(capturedItem, imageData: coverData)
                        }
                    }
                }
            }
        }

        // Phase 4: Tags
        prog.phase = .tags
        progress(prog)

        // Collect all unique tag names used by imported items
        var usedTagNames: Set<String> = []
        for zItem in zItems {
            guard itemMap[zItem.itemID] != nil else { continue }
            let itemTagEntries = tagsByItem[zItem.itemID] ?? []
            for it in itemTagEntries {
                if let name = tagMap[it.tagID] {
                    usedTagNames.insert(name)
                }
            }
        }

        // Find or use the Tags property
        guard let tagsProperty = store.tagsProperty else {
            Log.error(Log.zotero, "Tags property not found")
            result.errors.append("Tags property not found in OakReader")
            return finalize(prog: &prog, result: result, progress: progress)
        }

        // Create tag options that don't already exist
        let existingOptionNames = Set(tagsProperty.options.map { $0.name })
        var tagOptionMap: [String: PropertyOption] = [:]

        // Map existing options
        for opt in tagsProperty.options {
            tagOptionMap[opt.name] = opt
        }

        var colorIndex = tagsProperty.options.count
        for tagName in usedTagNames.sorted() {
            if existingOptionNames.contains(tagName) { continue }
            let color = ZoteroFieldMapping.tagColors[colorIndex % ZoteroFieldMapping.tagColors.count]
            if let opt = store.addPropertyOption(propertyId: tagsProperty.id, name: tagName, colorHex: color) {
                tagOptionMap[tagName] = opt
                result.tagCount += 1
                colorIndex += 1
            }
        }

        // Reload the tags property to pick up new options
        let updatedTagsProperty: PropertyDefinition
        if let refreshed = store.properties.first(where: { $0.name == "Tags" && $0.isSystem }) {
            updatedTagsProperty = refreshed
            // Refresh tagOptionMap with correct IDs
            for opt in refreshed.options {
                tagOptionMap[opt.name] = opt
            }
        } else {
            updatedTagsProperty = tagsProperty
        }

        // Assign tags to items
        prog.total = zItems.count
        prog.current = 0
        for zItem in zItems {
            prog.current += 1
            guard let libraryItem = libraryItemMap[zItem.itemID] else { continue }
            let itemTagEntries = tagsByItem[zItem.itemID] ?? []
            for it in itemTagEntries {
                guard let tagName = tagMap[it.tagID],
                      let option = tagOptionMap[tagName] else { continue }
                store.setItemSelectValue(item: libraryItem, property: updatedTagsProperty, option: option)
            }
        }

        // Phase 5: Collection assignments
        prog.phase = .collectionAssignments
        prog.total = zCollectionItems.count
        prog.current = 0
        progress(prog)

        for zCI in zCollectionItems {
            prog.current += 1
            progress(prog)
            guard let libraryItem = libraryItemMap[zCI.itemID],
                  let oakCollection = collectionMap[zCI.collectionID] else { continue }
            store.addItem(libraryItem, to: oakCollection)
        }

        return finalize(prog: &prog, result: result, progress: progress)
    }

    // MARK: - Helpers

    private func finalize(
        prog: inout ZoteroMigrationProgress,
        result: ZoteroMigrationResult,
        progress: (ZoteroMigrationProgress) -> Void
    ) -> ZoteroMigrationResult {
        prog.phase = .done
        prog.currentItemTitle = ""
        progress(prog)
        store.invalidate()

        Log.info(Log.zotero, "Migration complete: \(result.itemCount) items, \(result.pdfCount) PDFs, " +
            "\(result.htmlCount) web pages, \(result.collectionCount) collections, " +
            "\(result.tagCount) tags, \(result.errors.count) errors")
        return result
    }

    /// Check whether an item with the given source and key already exists in the database.
    private func itemExistsForSource(_ source: String, key: String) -> Bool {
        let count = try? store.database.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM items WHERE source = ? AND source_key = ?
            """, arguments: [source, key])
        }
        return (count ?? 0) ?? 0 > 0
    }

    /// Determine the OakReader item type from a Zotero attachment content type.
    private func oakItemType(for contentType: String?) -> ContentType {
        switch contentType {
        case "text/html", "application/xhtml+xml":
            return .html
        default:
            return .pdf
        }
    }

    /// Check if a URL string points to a video site (YouTube, Bilibili).
    private static func isVideoURL(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host.contains("youtube.com") || host.contains("youtu.be")
            || host.contains("bilibili.com") || host.contains("b23.tv")
    }

    /// Copy all sibling files from a Zotero storage directory to the OakReader attachment directory.
    /// This preserves relative links in HTML documents (images, CSS, JS referenced by the HTML).
    private func copyDirectoryContents(from sourceDir: URL, to destDir: URL, excluding fileName: String) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in contents {
            if fileURL.lastPathComponent == fileName { continue }
            let dest = destDir.appendingPathComponent(fileURL.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: fileURL, to: dest)
            }
        }
    }

    /// Supplement already-saved Zotero CSL data with HTML meta tags for HTML documents.
    /// Only fills in fields that are empty in the existing metadata.
    private func enrichHTMLMetadata(htmlURL: URL, itemId: String) {
        guard let htmlString = try? String(contentsOf: htmlURL, encoding: .utf8) else { return }

        // Load existing metadata saved from Zotero fields
        guard let existing = referenceService.fetchMetadata(forItemId: itemId) else {
            return
        }
        var csl = existing.cslItem

        var changed = false

        // og:site_name → containerTitle
        if (csl.containerTitle ?? "").isEmpty,
           let siteName = extractHTMLMetaContent(htmlString, property: "og:site_name") {
            csl.containerTitle = siteName
            changed = true
        }

        // author from HTML meta
        if (csl.author ?? []).isEmpty,
           let authorName = extractHTMLMetaContent(htmlString, name: "author")
            ?? extractHTMLMetaContent(htmlString, property: "article:author") {
            csl.author = [CSLName(family: authorName, given: nil, literal: authorName)]
            changed = true
        }

        // article:published_time → issued
        if csl.issued == nil,
           let pubTime = extractHTMLMetaContent(htmlString, property: "article:published_time") {
            let parts = pubTime.prefix(10).split(separator: "-").compactMap { Int($0) }
            if let year = parts.first {
                csl.issued = CSLDate(
                    year: year,
                    month: parts.count > 1 ? parts[1] : nil,
                    day: parts.count > 2 ? parts[2] : nil
                )
                changed = true
            }
        }

        // og:description / description → abstract
        if (csl.abstract ?? "").isEmpty,
           let desc = extractHTMLMetaContent(htmlString, property: "og:description")
            ?? extractHTMLMetaContent(htmlString, name: "description") {
            csl.abstract = desc
            changed = true
        }

        if changed {
            do {
                try referenceService.saveMetadata(csl, forItemId: itemId)
            } catch {
                Log.error(Log.zotero, "Failed to enrich HTML metadata: \(error)")
            }
        }
    }

    /// Extract content from `<meta property="..." content="...">` tags.
    private func extractHTMLMetaContent(_ html: String, property: String) -> String? {
        let patterns = [
            "<meta[^>]+property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"']",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Extract content from `<meta name="..." content="...">` tags.
    private func extractHTMLMetaContent(_ html: String, name: String) -> String? {
        let patterns = [
            "<meta[^>]+name=[\"']\(NSRegularExpression.escapedPattern(for: name))[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+name=[\"']\(NSRegularExpression.escapedPattern(for: name))[\"']",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Resolve the file path from a Zotero attachment entry.
    /// Zotero stores paths as "storage:filename" for stored files.
    private func resolveAttachmentPath(_ att: ZoteroAttachment, dataDirectory: URL) -> URL? {
        guard let path = att.path else { return nil }

        if path.hasPrefix("storage:") {
            // Stored attachment: {dataDir}/storage/{key}/{filename}
            let fileName = String(path.dropFirst("storage:".count))
            return dataDirectory
                .appendingPathComponent("storage")
                .appendingPathComponent(att.key)
                .appendingPathComponent(fileName)
        }

        // Linked file: absolute path or relative path
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        // Relative path from data directory
        return dataDirectory.appendingPathComponent(path)
    }

    /// Parse a Zotero date string (e.g. "2024-03-15", "2024", "March 15, 2024") into a CSLDate.
    private func parseZoteroDate(_ dateStr: String) -> CSLDate {
        let trimmed = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try ISO-style: "2024-03-15", "2024-03", "2024"
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        if let year = parts.first, year > 0 {
            return CSLDate(
                year: year,
                month: parts.count > 1 ? parts[1] : nil,
                day: parts.count > 2 ? parts[2] : nil
            )
        }

        // Fallback: store as raw date
        return CSLDate(raw: trimmed)
    }

    /// Topologically sort collections so that parent collections are processed before children.
    private func topologicalSort(_ collections: [ZoteroCollection]) -> [ZoteroCollection] {
        var sorted: [ZoteroCollection] = []
        var remaining = collections
        var processedIDs: Set<Int> = []

        while !remaining.isEmpty {
            let batch = remaining.filter { coll in
                coll.parentCollectionID == nil || processedIDs.contains(coll.parentCollectionID!)
            }
            if batch.isEmpty {
                // Circular reference fallback: just append remaining
                sorted.append(contentsOf: remaining)
                break
            }
            sorted.append(contentsOf: batch)
            processedIDs.formUnion(batch.map(\.collectionID))
            remaining.removeAll { processedIDs.contains($0.collectionID) }
        }

        return sorted
    }
}
