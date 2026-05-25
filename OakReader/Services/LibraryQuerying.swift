import Foundation

/// Read-only seam for library queries. Allows consumers (e.g. ImportService) to depend on
/// the query interface without coupling to the full LibraryStore implementation.
protocol LibraryQuerying {
    func findItem(byId id: UUID) -> LibraryItem?
    func findItem(byCiteKey citeKey: String) -> LibraryItem?
    func findItem(byStorageKey key: String) -> LibraryItem?
    func findItem(bySource source: String, sourceKey: String) -> LibraryItem?
    func findItem(byFileName fileName: String) -> LibraryItem?
    func findItem(bySourceURL url: URL) -> LibraryItem?
    var items: [LibraryItem] { get }
    var filteredItems: [LibraryItem] { get }
    var collections: [PDFCollection] { get }
    var properties: [PropertyDefinition] { get }
}

extension LibraryStore: LibraryQuerying {}
