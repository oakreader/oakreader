import Foundation
import GRDB

// MARK: - GRDB Records (internal, map directly to DB columns)

struct DocumentRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "documents"

    var id: String
    var userId: String
    var storageKey: String
    var originalFileName: String
    var title: String
    var author: String
    var pageCount: Int
    var fileSize: Int64
    var isFavorite: Bool
    var dateLastOpened: String?
    var syncStatus: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case userId = "user_id"
        case storageKey = "storage_key"
        case originalFileName = "original_file_name"
        case title, author
        case pageCount = "page_count"
        case fileSize = "file_size"
        case isFavorite = "is_favorite"
        case dateLastOpened = "date_last_opened"
        case syncStatus = "sync_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CollectionRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "collections"

    var id: String
    var userId: String
    var name: String
    var icon: String
    var sortOrder: Int
    var parentId: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case userId = "user_id"
        case name, icon
        case sortOrder = "sort_order"
        case parentId = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct TagRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "tags"

    var id: String
    var userId: String
    var name: String
    var colorHex: String
    var position: Int
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case userId = "user_id"
        case name
        case colorHex = "color_hex"
        case position
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DocumentCollectionRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "document_collections"

    var documentId: String
    var collectionId: String
    var createdAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case documentId = "document_id"
        case collectionId = "collection_id"
        case createdAt = "created_at"
    }
}

struct DocumentTagRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "document_tags"

    var documentId: String
    var tagId: String
    var createdAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case documentId = "document_id"
        case tagId = "tag_id"
        case createdAt = "created_at"
    }
}

struct ChatSessionRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "chat_sessions"

    var id: String
    var userId: String
    var documentId: String
    var title: String
    var messageCount: Int
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case userId = "user_id"
        case documentId = "document_id"
        case title
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

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

// MARK: - Tag Colors (Zotero palette)

enum TagColor: String, CaseIterable, Identifiable {
    case red, orange, gray, green, teal, blue, indigo, purple, plum

    var id: String { rawValue }

    var hex: String {
        switch self {
        case .red:    return "FF6666"
        case .orange: return "FF8C19"
        case .gray:   return "999999"
        case .green:  return "5FB236"
        case .teal:   return "009980"
        case .blue:   return "2EA8E5"
        case .indigo: return "576DD9"
        case .purple: return "A28AE5"
        case .plum:   return "A6507B"
        }
    }
}

// MARK: - Enums

enum SyncStatus: String, Codable {
    case local
    case synced
    case pendingUpload
    case pendingDownload
    case conflict
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case dateAdded = "Date Added"
    case dateOpened = "Last Opened"
    case title = "Title"
    case author = "Author"
    case fileSize = "File Size"

    var id: String { rawValue }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All PDFs"
    case recentlyAdded = "Recently Added"
    case favorites = "Favorites"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "books.vertical"
        case .recentlyAdded: return "clock"
        case .favorites: return "star"
        }
    }
}

// MARK: - Local user ID

/// Default user ID for Phase 1 (local-only). Will become a real user ID in Phase 2 (sync).
let localUserId = "local"
