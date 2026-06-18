import Foundation

/// Persists region-capture screenshots taken into a note's compose box and hands
/// back an absolute `file://` URL string to embed as markdown (`![](…)`). Images
/// live under `~/OakReader[-Dev]/note-images/` — flat, UUID-named, never rewritten.
enum NoteImageStore {
    static var directory: URL {
        CatalogDatabase.dataDirectory.appendingPathComponent("note-images", isDirectory: true)
    }

    /// Store already-encoded PNG bytes (e.g. an area-capture from the viewer).
    static func save(pngData: Data) -> String? {
        write(pngData, ext: "png")
    }

    private static func write(_ data: Data, ext: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = directory.appendingPathComponent(UUID().uuidString + "." + ext)
            try data.write(to: dest)
            return dest.absoluteString
        } catch {
            return nil
        }
    }
}
