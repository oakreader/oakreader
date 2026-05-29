import Foundation

/// Discriminator for embed subtypes.
enum EmbedType: String, Codable {
    case youtube
    case link       // generic bookmark — any URL saved as "link" mode
}

/// Metadata for embed documents (YouTube, generic links), stored as metadata.json.
struct MediaMetadata: Codable {
    let title: String
    let author: String              // Channel name / site name
    let sourceURL: URL              // Original URL
    let duration: Int?              // Seconds (YouTube only)
    let thumbnailURL: URL?
    let publishedAt: String?        // ISO 8601
    let description: String?
    let embedType: String?          // "youtube" | "link", nil → treated as link

    /// Resolved enum from the optional string field. A missing/unknown tag
    /// resolves to `.link`, matching how `OakServer` defaults untagged clips.
    var resolvedEmbedType: EmbedType {
        EmbedType(rawValue: embedType ?? "link") ?? .link
    }
}

/// Lightweight data holder for embed documents (YouTube, generic links).
/// Not an NSDocument — media items are read-only.
final class MediaDocument {
    let storageDirectory: URL
    let metadata: MediaMetadata
    let transcriptURL: URL?         // transcript.txt if available
    let embedHTMLURL: URL?          // embed.html for link rendering
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

        let embedHTML = storageDirectory.appendingPathComponent("embed.html")
        self.embedHTMLURL = FileManager.default.fileExists(atPath: embedHTML.path) ? embedHTML : nil
    }
}

/// Builds a real, openable platform URL that jumps to `seconds` into a media item's
/// source. Podcasts and videos have no local seekable copy, so a `?time=` citation
/// must open the source platform at that moment: YouTube uses `&t=<n>s`, Apple
/// Podcasts uses `&t=<n>` (integer seconds), and anything else falls back to a
/// best-effort `#t=<n>` media fragment (honored by direct HTML5 audio/video).
enum MediaTimestampLink {
    static func url(forSource source: URL, atSeconds seconds: Double) -> URL {
        let t = max(0, Int(seconds.rounded()))
        guard var comps = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            return source
        }
        let host = (comps.host ?? "").lowercased()

        func setQuery(_ name: String, _ value: String) {
            var items = (comps.queryItems ?? []).filter { $0.name != name }
            items.append(URLQueryItem(name: name, value: value))
            comps.queryItems = items
        }

        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            setQuery("t", "\(t)s")
        } else if host == "podcasts.apple.com" || host.hasSuffix(".podcasts.apple.com") {
            setQuery("t", "\(t)")
        } else {
            comps.fragment = "t=\(t)"
        }
        return comps.url ?? source
    }
}
