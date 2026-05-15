import Foundation

/// Lightweight data holder for web snapshot HTML files.
/// Not an NSDocument — snapshots are read-only, no autosave needed.
final class WebSnapshotDocument {
    let htmlURL: URL
    let sourceURL: URL?

    init(htmlURL: URL, sourceURL: URL? = nil) throws {
        guard FileManager.default.fileExists(atPath: htmlURL.path) else {
            throw OakReaderError.fileNotFound(htmlURL)
        }
        self.htmlURL = htmlURL
        self.sourceURL = sourceURL
    }
}
