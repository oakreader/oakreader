import Foundation

// MARK: - Attachment

/// A file attached to a library item (PDF, web snapshot, or embed).
struct Attachment: Identifiable, Hashable {
    let id: UUID
    let storageKey: String
    let itemStorageKey: String
    var fileName: String
    var attachmentType: ItemType
    var sourceURL: URL?
    var fileSize: Int64
    var pageCount: Int
    var isPrimary: Bool

    /// File URL within managed storage.
    var fileURL: URL {
        let dir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: storageKey)
        switch attachmentType {
        case .pdf:
            let namedURL = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: namedURL.path) {
                return namedURL
            }
            return dir.appendingPathComponent("document.pdf")
        case .webSnapshot:
            return dir.appendingPathComponent(fileName)
        case .embed:
            return dir.appendingPathComponent("metadata.json")
        }
    }

    /// Attachment directory within managed storage.
    var documentDirectory: URL {
        CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: storageKey)
    }

    /// Cover image URL for this attachment.
    var coverURL: URL {
        CatalogDatabase.attachmentCoverURL(itemStorageKey: itemStorageKey, attachmentStorageKey: storageKey)
    }

    init(record: AttachmentRecord, itemStorageKey: String) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.storageKey = record.storageKey
        self.itemStorageKey = itemStorageKey
        self.fileName = record.fileName
        self.attachmentType = ItemType(rawValue: record.attachmentType) ?? .pdf
        self.sourceURL = record.sourceURL.flatMap { URL(string: $0) }
        self.fileSize = record.fileSize
        self.pageCount = record.pageCount
        self.isPrimary = record.isPrimary
    }
}

// MARK: - View-Facing Types

/// Library item displayed in the table and detail panel.
/// Composed from ItemRecord + attachments + related property values/collections + cover image.
struct LibraryItem: Identifiable, Hashable {
    let id: UUID
    let storageKey: String
    var title: String
    var author: String
    var dateAdded: Date
    var lastOpenedAt: Date?
    var isFavorite: Bool
    var syncStatus: SyncStatus
    var isInbox: Bool
    var citeKey: String?

    // Attachments (files belonging to this item)
    var attachments: [Attachment]

    // Populated by the store from relationships / filesystem
    var propertyValues: [PropertyValue]
    var collections: [PDFCollection]
    var coverImageData: Data?
    var referenceMetadata: ReferenceMetadata?

    // MARK: - Primary attachment delegates

    var primaryAttachment: Attachment? {
        attachments.first { $0.isPrimary } ?? attachments.first
    }

    var itemType: ItemType { primaryAttachment?.attachmentType ?? .pdf }
    var fileName: String { primaryAttachment?.fileName ?? "" }
    var fileSize: Int64 { primaryAttachment?.fileSize ?? 0 }
    var pageCount: Int { primaryAttachment?.pageCount ?? 0 }
    var sourceURL: URL? { primaryAttachment?.sourceURL }

    /// File URL of the primary attachment within managed storage.
    var fileURL: URL {
        primaryAttachment?.fileURL ?? CatalogDatabase.documentDirectory(storageKey: storageKey)
    }

    /// Item-level directory within managed storage (notes, sessions live here).
    var documentDirectory: URL {
        CatalogDatabase.documentDirectory(storageKey: storageKey)
    }

    static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Record conversion

    init(record: ItemRecord, attachments: [Attachment] = [], propertyValues: [PropertyValue] = [], collections: [PDFCollection] = [], coverImageData: Data? = nil, referenceMetadata: ReferenceMetadata? = nil) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.storageKey = record.storageKey
        self.title = record.title
        self.author = record.author
        self.dateAdded = Date(iso8601String: record.createdAt) ?? Date()
        self.lastOpenedAt = record.lastOpenedAt.flatMap { Date(iso8601String: $0) }
        self.isFavorite = record.isFavorite
        self.syncStatus = SyncStatus(rawValue: record.syncStatus) ?? .local
        self.isInbox = record.isInbox
        self.citeKey = record.citeKey
        self.attachments = attachments
        self.propertyValues = propertyValues
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
    var isSmart: Bool
    var isSystem: Bool
    var filterRules: FilterRuleSet?

    // Populated by the store
    var subcollections: [PDFCollection]
    /// Number of items in this collection (populated by the store).
    var itemCount: Int

    static func == (lhs: PDFCollection, rhs: PDFCollection) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.icon == rhs.icon &&
        lhs.sortOrder == rhs.sortOrder &&
        lhs.parentId == rhs.parentId &&
        lhs.isSmart == rhs.isSmart &&
        lhs.isSystem == rhs.isSystem &&
        lhs.filterRules == rhs.filterRules &&
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
        self.isSmart = record.isSmart
        self.isSystem = record.isSystem
        if let json = record.filterRules, let data = json.data(using: .utf8) {
            self.filterRules = try? JSONDecoder().decode(FilterRuleSet.self, from: data)
        } else {
            self.filterRules = nil
        }
        self.subcollections = subcollections
        self.itemCount = itemCount
    }
}

// MARK: - Property System Types

enum PropertyType: String, Codable, CaseIterable {
    case multiSelect = "multi_select"
    case singleSelect = "single_select"
    case number
    case text
}

/// A property definition (e.g., "Tags", "Status", "Rating").
struct PropertyDefinition: Identifiable, Hashable {
    let id: UUID
    var name: String
    var type: PropertyType
    var icon: String
    var position: Int
    var isSystem: Bool
    var options: [PropertyOption]

    init(record: PropertyRecord, options: [PropertyOption] = []) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.name = record.name
        self.type = PropertyType(rawValue: record.type) ?? .text
        self.icon = record.icon
        self.position = record.position
        self.isSystem = record.isSystem
        self.options = options
    }
}

/// An option within a select-type property (e.g., "Important" tag, "Reading" status).
struct PropertyOption: Identifiable, Hashable {
    let id: UUID
    var propertyId: UUID
    var name: String
    var colorHex: String
    var position: Int

    init(record: PropertyOptionRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.propertyId = UUID(uuidString: record.propertyId) ?? UUID()
        self.name = record.name
        self.colorHex = record.colorHex
        self.position = record.position
    }

    init(id: UUID = UUID(), propertyId: UUID, name: String, colorHex: String, position: Int = 0) {
        self.id = id
        self.propertyId = propertyId
        self.name = name
        self.colorHex = colorHex
        self.position = position
    }
}

/// A concrete value assigned to an item for a given property.
struct PropertyValue: Identifiable, Hashable {
    let id: UUID
    var propertyId: UUID
    var propertyName: String
    var propertyType: PropertyType
    var option: PropertyOption?
    var textValue: String?
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
