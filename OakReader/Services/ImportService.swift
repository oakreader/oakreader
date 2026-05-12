import Foundation
import PDFKit
import AppKit
import CommonCrypto

/// Handles PDF and web snapshot import: copy to managed storage, extract metadata, generate cover, insert into DB.
final class ImportService {
    let store: LibraryStore
    let coverService: LibraryCoverService
    let referenceService: ReferenceService
    var semanticIndexService: SemanticIndexService?

    init(store: LibraryStore, coverService: LibraryCoverService, referenceService: ReferenceService) {
        self.store = store
        self.coverService = coverService
        self.referenceService = referenceService
    }

    // MARK: - Duplicate Detection

    /// Hash the first 64KB of a file for duplicate detection.
    func hashPrefix(of url: URL) -> String? {
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
    func findByHash(_ hash: String) -> LibraryItem? {
        for item in store.items {
            let pdfURL = item.fileURL
            if let existingHash = hashPrefix(of: pdfURL), existingHash == hash {
                return item
            }
        }
        return nil
    }
}
