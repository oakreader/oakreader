import AppKit
import Foundation

/// Canonical, relocatable URL for a note image stored on disk under its library item.
///
///     oak://image/{itemKey}/{fileName}  ⇄  …/storage/{itemKey}/images/{fileName}
///
/// Notes live in the `annotations` table; their pasted/captured images live on disk
/// (BLOBs would bloat the catalog DB). Embedding the item *storage key* rather than
/// an absolute `file://` path keeps notes relocatable — the data directory can move,
/// and Debug (`~/OakReader-Dev`) vs Release (`~/OakReader`) differ — without rewriting
/// every link. Resolution is a pure string→path transform: no database lookup.
enum OakNoteImageURL {
    static let scheme = "oak"
    static let host = "image"

    static func make(itemKey: String, fileName: String) -> String {
        "\(scheme)://\(host)/\(itemKey)/\(fileName)"
    }

    /// Resolve an `oak://image/...` URL to its on-disk file URL, or `nil` for any
    /// other URL (callers then fall back to their existing file/path handling).
    static func resolveToFile(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              url.scheme == scheme, url.host == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }  // [itemKey, fileName]
        guard parts.count == 2 else { return nil }
        return CatalogDatabase.documentDirectory(storageKey: parts[0])
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(parts[1])
    }

    /// Load the image a URL string points at. Resolves the relocatable
    /// `oak://image/...` scheme first; for any other URL (legacy absolute `file://`,
    /// remote `http(s)://`) it falls back to loading the URL as-is.
    static func image(_ urlString: String) -> NSImage? {
        if let file = resolveToFile(urlString) { return NSImage(contentsOf: file) }
        return URL(string: urlString).flatMap { NSImage(contentsOf: $0) }
    }
}
