import Foundation

/// Lightweight data holder for markdown files in the library.
/// Supports reading and writing content back to disk.
final class MarkdownDocument {
    let fileURL: URL
    var content: String

    init(fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw OakReaderError.fileNotFound(fileURL)
        }
        self.fileURL = fileURL
        self.content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func save() {
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
