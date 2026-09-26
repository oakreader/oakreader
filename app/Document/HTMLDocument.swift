import Foundation

/// Lightweight data holder for HTML document files.
/// Not an NSDocument — HTML documents are read-only, no autosave needed.
final class HTMLDocument {
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
