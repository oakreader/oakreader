import Foundation

/// Persists region-capture screenshots taken into a note's compose box. Images live
/// under their owning library item — `…/storage/{itemKey}/images/{uuid}.png` — so they
/// are removed when the item is deleted and travel with it on export/backup. Hands back
/// a relocatable `oak://image/...` URL string to embed as markdown (`![](…)`); see
/// `OakNoteImageURL` for the URL ⇄ path mapping.
enum NoteImageStore {
    static func directory(itemKey: String) -> URL {
        CatalogDatabase.documentDirectory(storageKey: itemKey)
            .appendingPathComponent("images", isDirectory: true)
    }

    /// Store already-encoded PNG bytes under `itemKey`'s images folder, returning the
    /// `oak://image/...` URL to embed, or nil on failure.
    static func save(pngData: Data, itemKey: String) -> String? {
        write(pngData, ext: "png", itemKey: itemKey)
    }

    private static func write(_ data: Data, ext: String, itemKey: String) -> String? {
        do {
            let dir = directory(itemKey: itemKey)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = UUID().uuidString + "." + ext
            try data.write(to: dir.appendingPathComponent(name))
            return OakNoteImageURL.make(itemKey: itemKey, fileName: name)
        } catch {
            return nil
        }
    }
}
