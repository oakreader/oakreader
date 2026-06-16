import AppKit
import Foundation

/// Persists images dropped/pasted/picked into a note's compose box and hands back
/// an absolute `file://` URL string to embed as markdown (`![](…)`). Images live
/// under `~/OakReader[-Dev]/note-images/` — flat, UUID-named, never rewritten.
enum NoteImageStore {
    static var directory: URL {
        CatalogDatabase.dataDirectory.appendingPathComponent("note-images", isDirectory: true)
    }

    /// Encode an in-memory image (clipboard paste / drag) to PNG and store it.
    static func save(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return write(png, ext: "png")
    }

    /// Store already-encoded PNG bytes (e.g. an area-capture from the viewer).
    static func save(pngData: Data) -> String? {
        write(pngData, ext: "png")
    }

    /// Copy an existing image file (file picker / dropped file) into the store.
    static func save(fileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        return write(data, ext: ext)
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
