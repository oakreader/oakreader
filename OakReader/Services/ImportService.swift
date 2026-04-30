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
    func importPDF(from sourceURL: URL) -> PDFLibraryItem? {
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
        let storageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: storageKey)
        let destURL = CatalogDatabase.documentPDFURL(storageKey: storageKey, fileName: sourceURL.lastPathComponent)

        do {
            // Create document directory
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)

            // Create sessions subdirectory
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: storageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            // Copy PDF to managed storage
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
        let record = DocumentRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: storageKey,
            originalFileName: sourceURL.lastPathComponent,
            title: title,
            author: author,
            pageCount: pageCount,
            fileSize: fileSize,
            isFavorite: false,
            dateLastOpened: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now,
            documentType: DocumentType.pdf.rawValue,
            sourceURL: nil,
            isInInbox: false
        )

        guard let item = store.insertDocument(record) else {
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
            await autoExtractReference(documentId: docId.uuidString, pdfURL: destURL)
        }

        return item
    }

    // MARK: - Web Snapshot Import

    /// Import an HTML web snapshot into managed storage.
    @discardableResult
    func importWebSnapshot(from sourceURL: URL, originalPageURL: URL? = nil, title: String? = nil) -> PDFLibraryItem? {
        // Duplicate detection
        if let hash = hashPrefix(of: sourceURL),
           let existing = findByHash(hash) {
            return existing
        }

        let docId = UUID()
        let storageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: storageKey)
        let destURL = CatalogDatabase.documentHTMLURL(storageKey: storageKey, fileName: sourceURL.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)

            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: storageKey)
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
        let record = DocumentRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: storageKey,
            originalFileName: sourceURL.lastPathComponent,
            title: resolvedTitle,
            author: "",
            pageCount: 1,
            fileSize: fileSize,
            isFavorite: false,
            dateLastOpened: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now,
            documentType: DocumentType.webSnapshot.rawValue,
            sourceURL: originalPageURL?.absoluteString,
            isInInbox: originalPageURL != nil
        )

        guard let item = store.insertDocument(record) else {
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
    ) -> PDFLibraryItem? {
        // Duplicate detection by source URL
        if let existing = store.items.first(where: { $0.sourceURL == sourceURL }) {
            return existing
        }

        let docId = UUID()
        let storageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: storageKey)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: storageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            // Write metadata.json
            let metadataURL = CatalogDatabase.documentMetadataURL(storageKey: storageKey)
            let encoded = try JSONEncoder().encode(metadata)
            try encoded.write(to: metadataURL, options: .atomic)

            // Write transcript
            if let transcript, !transcript.isEmpty {
                let transcriptURL = CatalogDatabase.documentTranscriptURL(storageKey: storageKey)
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            }

            // Write thumbnail as cover
            if let thumbnailData {
                let coverURL = CatalogDatabase.documentCoverURL(storageKey: storageKey)
                try thumbnailData.write(to: coverURL, options: .atomic)
            }
        } catch {
            Log.error(Log.importer, "Failed to import embed: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        let now = Date().iso8601String
        let record = DocumentRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: storageKey,
            originalFileName: "metadata.json",
            title: title,
            author: author,
            pageCount: duration ?? 0,
            fileSize: 0,
            isFavorite: false,
            dateLastOpened: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now,
            documentType: DocumentType.embed.rawValue,
            sourceURL: sourceURL.absoluteString,
            isInInbox: true
        )

        guard let item = store.insertDocument(record) else {
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        return item
    }

    // MARK: - Reference Extraction

    /// Extract DOI from PDF text and fetch metadata from CrossRef.
    private func autoExtractReference(documentId: String, pdfURL: URL) async {
        guard let doi = DOIExtractorService.extractDOI(from: pdfURL) else { return }

        do {
            let cslItem = try await CrossRefService.fetchMetadata(doi: doi)
            try referenceService.saveMetadata(cslItem, forDocumentId: documentId)
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
    private func findByHash(_ hash: String) -> PDFLibraryItem? {
        for item in store.items {
            let pdfURL = item.fileURL
            if let existingHash = hashPrefix(of: pdfURL), existingHash == hash {
                return item
            }
        }
        return nil
    }
}
