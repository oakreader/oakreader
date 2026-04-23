import Foundation
import PDFKit
import CommonCrypto

/// Handles PDF import: copy to managed storage, extract metadata, generate cover, insert into DB.
final class ImportService {
    let store: LibraryStore
    let coverService: LibraryCoverService

    init(store: LibraryStore, coverService: LibraryCoverService) {
        self.store = store
        self.coverService = coverService
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
            NSLog("[Import] Failed to copy PDF: \(error)")
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
            updatedAt: now
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

        return item
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
