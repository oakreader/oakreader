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
    var documentType: String
    var sourceURL: String?

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
        case documentType = "document_type"
        case sourceURL = "source_url"
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
