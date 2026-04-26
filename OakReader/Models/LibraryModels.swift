import Foundation

// MARK: - View-Facing Types (backward-compatible names)

/// Library item displayed in the table and detail panel.
/// Composed from DocumentRecord + related tags/collections + cover image.
struct PDFLibraryItem: Identifiable, Hashable {
    let id: UUID
    let storageKey: String
    var fileName: String
    var title: String
    var author: String
    var dateAdded: Date
    var dateLastOpened: Date?
    var pageCount: Int
    var fileSize: Int64
    var isFavorite: Bool
    var syncStatus: SyncStatus

    // Populated by the store from relationships / filesystem
    var tags: [PDFTag]
    var collections: [PDFCollection]
    var coverImageData: Data?

    /// PDF file URL within managed storage.
    /// Falls back to legacy "document.pdf" for items imported before the rename.
    var fileURL: URL {
        let url = CatalogDatabase.documentPDFURL(storageKey: storageKey, fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // Fallback for legacy imports
        return CatalogDatabase.documentPDFURL(storageKey: storageKey)
    }

    /// Document directory within managed storage.
    var documentDirectory: URL {
        CatalogDatabase.documentDirectory(storageKey: storageKey)
    }

    static func == (lhs: PDFLibraryItem, rhs: PDFLibraryItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Record conversion

    init(record: DocumentRecord, tags: [PDFTag] = [], collections: [PDFCollection] = [], coverImageData: Data? = nil) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.storageKey = record.storageKey
        self.fileName = record.originalFileName
        self.title = record.title
        self.author = record.author
        self.dateAdded = Date(iso8601String: record.createdAt) ?? Date()
        self.dateLastOpened = record.dateLastOpened.flatMap { Date(iso8601String: $0) }
        self.pageCount = record.pageCount
        self.fileSize = record.fileSize
        self.isFavorite = record.isFavorite
        self.syncStatus = SyncStatus(rawValue: record.syncStatus) ?? .local
        self.tags = tags
        self.collections = collections
        self.coverImageData = coverImageData
    }
}

/// Collection displayed in the sidebar.
struct PDFCollection: Identifiable, Hashable {
    let id: UUID
    var name: String
    var icon: String
    var sortOrder: Int
    var parentId: UUID?

    // Populated by the store
    var subcollections: [PDFCollection]
    /// Number of documents in this collection (populated by the store).
    var itemCount: Int

    static func == (lhs: PDFCollection, rhs: PDFCollection) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    init(record: CollectionRecord, subcollections: [PDFCollection] = [], itemCount: Int = 0) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.name = record.name
        self.icon = record.icon
        self.sortOrder = record.sortOrder
        self.parentId = record.parentId.flatMap { UUID(uuidString: $0) }
        self.subcollections = subcollections
        self.itemCount = itemCount
    }
}

/// Tag displayed as colored swatches in the table.
struct PDFTag: Identifiable, Hashable {
    let id: UUID
    var name: String
    var colorHex: String
    var position: Int

    init(record: TagRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.name = record.name
        self.colorHex = record.colorHex
        self.position = record.position
    }

    init(id: UUID = UUID(), name: String, colorHex: String, position: Int = 0) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.position = position
    }
}
