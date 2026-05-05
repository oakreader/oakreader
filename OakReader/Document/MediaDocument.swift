import Foundation

/// Discriminator for embed subtypes.
enum EmbedType: String, Codable {
    case youtube
    case twitter
    case link       // generic bookmark — any URL saved as "link" mode
}

/// Metadata for embed documents (YouTube, Twitter, generic links), stored as metadata.json.
struct MediaMetadata: Codable {
    let title: String
    let author: String              // Channel name / @handle / site name
    let sourceURL: URL              // Original URL
    let duration: Int?              // Seconds (YouTube only)
    let thumbnailURL: URL?
    let publishedAt: String?        // ISO 8601
    let description: String?
    let embedType: String?          // "youtube" | "twitter" | "link", nil → defaults to "youtube"

    /// Resolved enum from the optional string field (backward-compatible).
    var resolvedEmbedType: EmbedType {
        EmbedType(rawValue: embedType ?? "youtube") ?? .youtube
    }
}

/// Lightweight data holder for embed documents (YouTube, Twitter posts, generic links).
/// Not an NSDocument — media items are read-only.
final class MediaDocument {
    let storageDirectory: URL
    let metadata: MediaMetadata
    let transcriptURL: URL?         // transcript.txt if available
    let chaptersURL: URL?           // chapters.json if available
    let highlightsURL: URL?         // highlights.json if available
    let embedHTMLURL: URL?          // embed.html for tweet/link rendering
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

        let highlights = storageDirectory.appendingPathComponent("highlights.json")
        self.highlightsURL = FileManager.default.fileExists(atPath: highlights.path) ? highlights : nil

        let embedHTML = storageDirectory.appendingPathComponent("embed.html")
        self.embedHTMLURL = FileManager.default.fileExists(atPath: embedHTML.path) ? embedHTML : nil
    }
}
