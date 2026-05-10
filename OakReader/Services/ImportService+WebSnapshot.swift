import Foundation

extension ImportService {
    // MARK: - Web Snapshot Import

    /// Import an HTML web snapshot into managed storage.
    @discardableResult
    func importWebSnapshot(from sourceURL: URL, originalPageURL: URL? = nil, title: String? = nil) -> LibraryItem? {
        // Duplicate detection
        if let hash = hashPrefix(of: sourceURL),
           let existing = findByHash(hash) {
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
            Log.error(Log.importer, "Failed to copy HTML snapshot: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Extract title from HTML <title> tag if not provided
        var resolvedTitle = title ?? sourceURL.deletingPathExtension().lastPathComponent
        if title == nil, let htmlString = try? String(contentsOf: destURL, encoding: .utf8) {
            if let titleMatch = htmlString.range(of: "(?<=<title>)[^<]+", options: .regularExpression) {
                let extracted = String(htmlString[titleMatch]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    resolvedTitle = extracted
                }
            }
        }

        // File size
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
            title: resolvedTitle,
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
            attachmentType: ItemType.webSnapshot.rawValue,
            sourceURL: originalPageURL?.absoluteString,
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

        // Generate cover thumbnail asynchronously
        Task {
            if let coverData = await coverService.generateWebSnapshotCover(for: destURL) {
                await MainActor.run {
                    store.updateCover(item, imageData: coverData)
                }
            }
        }

        return item
    }

}
