import Foundation
import AVFoundation

extension ImportService {

    /// Audio file extensions accepted for import.
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "flac", "ogg"]

    /// Import an external audio file (e.g. from Voice Memos) without deleting the original.
    /// Copies to a temp location, probes duration via AVAsset, then delegates to `importAudioRecording`.
    @discardableResult
    func importAudioFile(from fileURL: URL) async -> LibraryItem? {
        // Duplicate detection before copying
        if let hash = hashPrefix(of: fileURL),
           let existing = findByHash(hash) {
            return existing
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + fileURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: fileURL, to: tempURL)
        } catch {
            Log.error(Log.importer, "Failed to copy audio file to temp: \(error)")
            return nil
        }

        // Probe duration
        let asset = AVURLAsset(url: tempURL)
        let duration: Int
        if let cmDuration = try? await asset.load(.duration), cmDuration.seconds.isFinite {
            duration = Int(cmDuration.seconds)
        } else {
            duration = 0
        }

        let title = fileURL.deletingPathExtension().lastPathComponent
        return importAudioRecording(from: tempURL, duration: duration, title: title)
    }

    /// Import an audio recording into managed storage.
    /// - Parameters:
    ///   - sourceURL: Path to the audio file (typically a temp M4A).
    ///   - duration: Duration in seconds (stored in `pageCount` field).
    ///   - title: Optional title; defaults to "Recording YYYY-MM-DD HH:mm".
    /// - Returns: The created library item, or an existing item if duplicate detected.
    @discardableResult
    func importAudioRecording(from sourceURL: URL, duration: Int, title: String? = nil) -> LibraryItem? {
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
        let fileName = sourceURL.lastPathComponent
        let destURL = CatalogDatabase.attachmentFileURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attStorageKey,
            fileName: fileName
        )

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.error(Log.importer, "Failed to copy audio file: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Clean up temp file
        try? FileManager.default.removeItem(at: sourceURL)

        // File size
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        // Title defaults to "Recording YYYY-MM-DD HH:mm"
        let displayTitle: String
        if let title, !title.isEmpty {
            displayTitle = title
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            displayTitle = "Recording \(formatter.string(from: Date()))"
        }

        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: displayTitle,
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
            fileName: fileName,
            contentType: ContentType.audio.rawValue,
            linkMode: LinkMode.importedFile.rawValue,
            sourceURL: nil,
            fileSize: fileSize,
            pageCount: duration,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        guard let item = store.insertItem(itemRecord, attachment: attRecord) else {
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        return item
    }
}
