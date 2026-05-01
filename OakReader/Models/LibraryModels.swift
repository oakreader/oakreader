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
    var documentType: DocumentType
    var sourceURL: URL?
    var isInInbox: Bool

    // Populated by the store from relationships / filesystem
    var tags: [PDFTag]
    var collections: [PDFCollection]
    var coverImageData: Data?
    var referenceMetadata: ReferenceMetadata?

    /// File URL within managed storage.
    /// For web snapshots, returns the HTML file path.
    /// For PDFs, falls back to legacy "document.pdf" for items imported before the rename.
    /// For embeds, returns the metadata.json path.
    var fileURL: URL {
        switch documentType {
        case .webSnapshot:
            return CatalogDatabase.documentHTMLURL(storageKey: storageKey, fileName: fileName)
        case .pdf:
            let url = CatalogDatabase.documentPDFURL(storageKey: storageKey, fileName: fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            // Fallback for legacy imports
            return CatalogDatabase.documentPDFURL(storageKey: storageKey)
        case .embed:
            return CatalogDatabase.documentMetadataURL(storageKey: storageKey)
        }
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

    init(record: DocumentRecord, tags: [PDFTag] = [], collections: [PDFCollection] = [], coverImageData: Data? = nil, referenceMetadata: ReferenceMetadata? = nil) {
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
        self.documentType = DocumentType(rawValue: record.documentType) ?? .pdf
        self.sourceURL = record.sourceURL.flatMap { URL(string: $0) }
        self.isInInbox = record.isInInbox
        self.tags = tags
        self.collections = collections
        self.coverImageData = coverImageData
        self.referenceMetadata = referenceMetadata
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
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.icon == rhs.icon &&
        lhs.sortOrder == rhs.sortOrder &&
        lhs.parentId == rhs.parentId &&
        lhs.itemCount == rhs.itemCount
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

// MARK: - Reference Metadata

/// Reference metadata for a library item, parsed from CSL JSON.
struct ReferenceMetadata: Hashable {
    let cslItem: CSLItem

    var type: String { cslItem.type }
    var displayType: CSLItemType? { CSLItemType(rawValue: cslItem.type) }
    var doi: String? { cslItem.DOI }
    var year: Int? { cslItem.issued?.year }
    var journal: String? { cslItem.containerTitle }

    /// Formatted author display string parsed from CSL JSON.
    var authorDisplayString: String {
        (cslItem.author ?? [])
            .map { $0.displayString }
            .joined(separator: ", ")
    }

    init(cslItem: CSLItem) {
        self.cslItem = cslItem
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let item = try? JSONDecoder().decode(CSLItem.self, from: data)
        else { return nil }
        self.cslItem = item
    }
}
