import Foundation

/// Metadata for YouTube videos and podcast episodes, stored as metadata.json.
struct MediaMetadata: Codable {
    let title: String
    let author: String              // Channel name / podcast name
    let sourceURL: URL              // Original YouTube/podcast URL
    let duration: Int?              // Seconds
    let thumbnailURL: URL?
    let publishedAt: String?        // ISO 8601
    let description: String?
    // Podcast-specific
    let feedURL: URL?               // RSS feed URL
    let episodeTitle: String?
}

/// Lightweight data holder for YouTube videos and podcast episodes.
/// Not an NSDocument — media items are read-only.
final class MediaDocument {
    let storageDirectory: URL
    let metadata: MediaMetadata
    let transcriptURL: URL?         // transcript.txt if available
    let audioURL: URL?              // audio.m4a for podcasts
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

        let audio = storageDirectory.appendingPathComponent("audio.m4a")
        self.audioURL = FileManager.default.fileExists(atPath: audio.path) ? audio : nil
    }
}
