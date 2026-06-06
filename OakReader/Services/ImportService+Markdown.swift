import Foundation

extension ImportService {
    // MARK: - Markdown Import

    /// Import a markdown file into managed storage.
    @discardableResult
    func importMarkdown(from sourceURL: URL) -> LibraryItem? {
        // Duplicate detection: hash first 64KB
        if let hash = hashPrefix(of: sourceURL),
           let existing = findByHash(hash) {
            return existing
        }

        if let existing = store.findItem(byFileName: sourceURL.lastPathComponent) {
            return existing
        }

        let docId = UUID()
        let attId = UUID()
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attStorageKey
        )
        let destURL = CatalogDatabase.attachmentFileURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent
        )

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)

            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.error(Log.importer, "Failed to copy markdown file: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Extract title from first # heading, fallback to filename
        var title = sourceURL.deletingPathExtension().lastPathComponent
        if let mdString = try? String(contentsOf: destURL, encoding: .utf8) {
            let lines = mdString.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !heading.isEmpty {
                        title = heading
                    }
                    break
                }
            }
        }

        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: title,
            author: "",
            lastOpenedAt: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now
        )

        let attRecord = AttachmentRecord(
            id: attId.uuidString,
            itemId: docId.uuidString,
            storageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent,
            contentType: ContentType.markdown.rawValue,
            linkMode: LinkMode.importedFile.rawValue,
            sourceURL: nil,
            fileSize: fileSize,
            pageCount: 1,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        guard let item = store.insertItem(itemRecord, attachment: attRecord) else {
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Auto-create reference metadata
        var csl = CSLItem(type: "document")
        csl.title = title
        let cal = Calendar.current
        let today = Date()
        csl.issued = CSLDate(
            year: cal.component(.year, from: today),
            month: cal.component(.month, from: today),
            day: cal.component(.day, from: today)
        )
        do {
            try referenceService.saveMetadata(csl, forItemId: docId.uuidString)
        } catch {
            Log.error(Log.importer, "Failed to save markdown reference metadata: \(error)")
        }

        // Full-text search index (FTS5)
        if let service = ftsIndexService {
            Task {
                await service.indexItem(
                    itemId: docId.uuidString,
                    contentType: ContentType.markdown.rawValue,
                    storageKey: itemStorageKey,
                    attStorageKey: attStorageKey,
                    fileName: sourceURL.lastPathComponent
                )
            }
        }

        return item
    }

}
