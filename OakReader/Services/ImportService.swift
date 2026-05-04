import Foundation
import PDFKit
import AppKit
import CommonCrypto

/// Handles PDF and web snapshot import: copy to managed storage, extract metadata, generate cover, insert into DB.
final class ImportService {
    let store: LibraryStore
    let coverService: LibraryCoverService
    let referenceService: ReferenceService

    init(store: LibraryStore, coverService: LibraryCoverService, referenceService: ReferenceService) {
        self.store = store
        self.coverService = coverService
        self.referenceService = referenceService
    }

    // MARK: - Import

    /// Import a PDF from any URL into managed storage.
    /// Returns the library item if successful, or the existing item if already imported.
    @discardableResult
    func importPDF(from sourceURL: URL) -> LibraryItem? {
        // Duplicate detection: hash first 64KB
        if let hash = hashPrefix(of: sourceURL),
           let existing = findByHash(hash) {
            return existing
        }

        // Check if already imported by filename (fallback)
        if let existing = store.findItem(byFileName: sourceURL.lastPathComponent) {
            return existing
        }

        let docId = UUID()
        let attId = UUID()
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
        let destURL = CatalogDatabase.attachmentFileURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey, fileName: sourceURL.lastPathComponent)

        do {
            // Create item directory and subdirectories
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: itemStorageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            // Copy PDF to attachment directory
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.error(Log.importer, "Failed to copy PDF: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Extract metadata
        var title = sourceURL.deletingPathExtension().lastPathComponent
        var author = ""
        var pageCount = 0

        if let pdfDoc = PDFDocument(url: destURL) {
            pageCount = pdfDoc.pageCount
            if let t = pdfDoc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty {
                title = t
            }
            if let a = pdfDoc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
                author = a
            }
        }

        // File size
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        // Insert into DB
        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: title,
            author: author,
            isFavorite: false,
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
            attachmentType: ItemType.pdf.rawValue,
            sourceURL: nil,
            fileSize: fileSize,
            pageCount: pageCount,
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
            if let coverData = await coverService.generateCover(for: destURL) {
                await MainActor.run {
                    store.updateCover(item, imageData: coverData)
                }
            }
        }

        // Auto-extract DOI and fetch reference metadata
        Task {
            await autoExtractReference(itemId: docId.uuidString, pdfURL: destURL)
        }

        return item
    }

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
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
        let destURL = CatalogDatabase.attachmentFileURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey, fileName: sourceURL.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: itemStorageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

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
            isFavorite: false,
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

    // MARK: - Embed Import

    /// Import an embed (YouTube) from Chrome extension payload.
    @discardableResult
    func importEmbed(
        title: String,
        author: String,
        sourceURL: URL,
        duration: Int?,
        thumbnailData: Data?,
        transcript: String?,
        metadata: MediaMetadata
    ) -> LibraryItem? {
        // Duplicate detection by source URL
        if let existing = store.items.first(where: { $0.sourceURL == sourceURL }) {
            return existing
        }

        let docId = UUID()
        let attId = UUID()
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: itemStorageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            // Write metadata.json to attachment directory
            let metadataURL = CatalogDatabase.attachmentMetadataURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
            let encoded = try JSONEncoder().encode(metadata)
            try encoded.write(to: metadataURL, options: .atomic)

            // Write transcript to attachment directory
            if let transcript, !transcript.isEmpty {
                let transcriptURL = CatalogDatabase.attachmentTranscriptURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            }

            // Write thumbnail as cover to attachment directory
            if let thumbnailData {
                let coverURL = CatalogDatabase.attachmentCoverURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
                try thumbnailData.write(to: coverURL, options: .atomic)
            }
        } catch {
            Log.error(Log.importer, "Failed to import embed: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: title,
            author: author,
            isFavorite: false,
            lastOpenedAt: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now
        )

        let attRecord = AttachmentRecord(
            id: attId.uuidString,
            itemId: docId.uuidString,
            storageKey: attStorageKey,
            fileName: "metadata.json",
            attachmentType: ItemType.embed.rawValue,
            sourceURL: sourceURL.absoluteString,
            fileSize: 0,
            pageCount: duration ?? 0,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        guard let item = store.insertItem(itemRecord, attachment: attRecord) else {
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Auto-create reference metadata with motion_picture type for video embeds
        var csl = CSLItem(type: "motion_picture")
        csl.title = title
        if !author.isEmpty {
            csl.author = [CSLName(family: author, given: nil)]
        }
        csl.URL = sourceURL.absoluteString
        try? referenceService.saveMetadata(csl, forItemId: docId.uuidString)
        store.invalidate()

        // Auto-generate chapters (native YouTube + AI fallback)
        let hasTranscript = transcript != nil && !transcript!.isEmpty
        Task {
            let service = ChapterGenerationService()
            await service.run(
                itemStorageKey: itemStorageKey,
                attachmentStorageKey: attStorageKey,
                sourceURL: sourceURL,
                duration: duration,
                transcriptAlreadyExists: hasTranscript
            )
        }

        return item
    }

    // MARK: - Reference Extraction

    /// Extract DOI from PDF text and fetch metadata from CrossRef.
    private func autoExtractReference(itemId: String, pdfURL: URL) async {
        guard let doi = DOIExtractorService.extractDOI(from: pdfURL) else { return }

        do {
            let cslItem = try await CrossRefService.fetchMetadata(doi: doi)
            try referenceService.saveMetadata(cslItem, forItemId: itemId)
            await MainActor.run {
                store.invalidate()
            }
        } catch {
            Log.error(Log.importer, "CrossRef lookup failed for DOI \(doi): \(error)")
        }
    }

    // MARK: - Duplicate Detection

    /// Hash the first 64KB of a file for duplicate detection.
    private func hashPrefix(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: 65536)
        guard !data.isEmpty else { return nil }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Find a document with the same hash prefix.
    /// Checks existing PDFs in storage by hashing their first 64KB.
    private func findByHash(_ hash: String) -> LibraryItem? {
        for item in store.items {
            let pdfURL = item.fileURL
            if let existingHash = hashPrefix(of: pdfURL), existingHash == hash {
                return item
            }
        }
        return nil
    }
}
