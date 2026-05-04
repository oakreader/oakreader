import Foundation

/// Metadata for embed documents (YouTube), stored as metadata.json.
struct MediaMetadata: Codable {
    let title: String
    let author: String              // Channel name
    let sourceURL: URL              // Original URL
    let duration: Int?              // Seconds
    let thumbnailURL: URL?
    let publishedAt: String?        // ISO 8601
    let description: String?
}

/// Lightweight data holder for embed documents (YouTube).
/// Not an NSDocument — media items are read-only.
final class MediaDocument {
    let storageDirectory: URL
    let metadata: MediaMetadata
    let transcriptURL: URL?         // transcript.txt if available
    let chaptersURL: URL?           // chapters.json if available
    let sourceURL: URL

    init(storageDirectory: URL) throws {
        self.storageDirectory = storageDirectory

        let metadataURL = storageDirectory.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw OakReaderError.fileNotFound(metadataURL)
        }
        let data = try Data(contentsOf: metadataURL)
        self.metadata = try JSONDecoder().decode(MediaMetadata.self, from: data)
        self.sourceURL = metadata.sourceURL

        let transcript = storageDirectory.appendingPathComponent("transcript.txt")
        self.transcriptURL = FileManager.default.fileExists(atPath: transcript.path) ? transcript : nil

        let chapters = storageDirectory.appendingPathComponent("chapters.json")
        self.chaptersURL = FileManager.default.fileExists(atPath: chapters.path) ? chapters : nil
    }
}
