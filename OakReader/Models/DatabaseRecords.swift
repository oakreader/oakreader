import Foundation
import GRDB

// MARK: - GRDB Records (internal, map directly to DB columns)

struct ItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "items"

    var id: String
    var userId: String
    var storageKey: String
    var title: String
    var author: String
    var lastOpenedAt: String?
    var syncStatus: String
    var createdAt: String
    var updatedAt: String
    var citeKey: String?
    var lastPosition: Double?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case userId = "user_id"
        case storageKey = "storage_key"
        case title, author
        case lastOpenedAt = "last_opened_at"
        case syncStatus = "sync_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case citeKey = "cite_key"
        case lastPosition = "last_position"
    }
}

struct AttachmentRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "attachments"

    var id: String
    var itemId: String
    var storageKey: String
    var fileName: String
    var attachmentType: String
    var sourceURL: String?
    var fileSize: Int64
    var pageCount: Int
    var isPrimary: Bool
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case itemId = "item_id"
        case storageKey = "storage_key"
        case fileName = "file_name"
        case attachmentType = "attachment_type"
        case sourceURL = "source_url"
        case fileSize = "file_size"
        case pageCount = "page_count"
        case isPrimary = "is_primary"
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
    var isSmart: Bool
    var isSystem: Bool
    var filterRules: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case userId = "user_id"
        case name, icon
        case sortOrder = "sort_order"
        case parentId = "parent_id"
        case isSmart = "is_smart"
        case isSystem = "is_system"
        case filterRules = "filter_rules"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CollectionItemRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "collection_items"

    var itemId: String
    var collectionId: String
    var createdAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case itemId = "item_id"
        case collectionId = "collection_id"
        case createdAt = "created_at"
    }
}

// MARK: - Property System

struct PropertyRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "properties"

    var id: String
    var name: String
    var type: String          // "multi_select", "single_select", "number", "text"
    var icon: String
    var position: Int
    var isSystem: Bool

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, name, type, icon, position
        case isSystem = "is_system"
    }
}

struct PropertyOptionRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "property_options"

    var id: String
    var propertyId: String
    var name: String
    var colorHex: String
    var position: Int

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case propertyId = "property_id"
        case name
        case colorHex = "color_hex"
        case position
    }
}

struct ItemPropertyValueRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "item_property_values"

    var id: String
    var itemId: String
    var propertyId: String
    var optionId: String?
    var textValue: String?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case itemId = "item_id"
        case propertyId = "property_id"
        case optionId = "option_id"
        case textValue = "text_value"
    }
}

// MARK: - Conversations

struct ConversationRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "conversations"

    var id: String
    var userId: String
    var itemId: String?
    var title: String
    var messageCount: Int
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case userId = "user_id"
        case itemId = "item_id"
        case title
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Notes

struct NoteRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "notes"

    var id: String
    var userId: String
    var itemId: String
    var title: String
    var isPinned: Bool
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case userId = "user_id"
        case itemId = "item_id"
        case title
        case isPinned = "is_pinned"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Citations

struct CitationRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "citations"

    var itemId: String          // PK, FK → items.id
    var cslJson: String         // Full CSL JSON string
    var cslType: String         // "article-journal", "book", etc.
    var doi: String?
    var year: Int?
    var containerTitle: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case itemId = "item_id"
        case cslJson = "csl_json"
        case cslType = "csl_type"
        case doi, year
        case containerTitle = "container_title"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
