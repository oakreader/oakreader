import Foundation

// MARK: - Column shapes
//
// One struct per table, with exactly its columns. These were GRDB records; the
// core owns the queries now, so what is left is the shape — still the layer the
// domain models are built from, because their `init(record:)` carries the real
// parsing (filter rule sets, CSL JSON, enum mapping) and there should be only
// one copy of it. The `CodingKeys` stay: they are the column names, which the
// wire mapping and the JSON encoding both need.

struct ItemRecord: Codable, Hashable {
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
    var source: String?
    var sourceKey: String?
    var extra: String?
    var processingStatus: String = "none"
    var deletedAt: String?

    enum CodingKeys: String, CodingKey {
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
        case source
        case sourceKey = "source_key"
        case extra
        case processingStatus = "processing_status"
        case deletedAt = "deleted_at"
    }
}

struct AttachmentRecord: Codable, Hashable {
    static let databaseTableName = "attachments"

    var id: String
    var itemId: String
    var storageKey: String
    var fileName: String
    var contentType: String
    var linkMode: String
    var sourceURL: String?
    var fileSize: Int64
    var pageCount: Int
    var isPrimary: Bool
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case itemId = "item_id"
        case storageKey = "storage_key"
        case fileName = "file_name"
        case contentType = "content_type"
        case linkMode = "link_mode"
        case sourceURL = "source_url"
        case fileSize = "file_size"
        case pageCount = "page_count"
        case isPrimary = "is_primary"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CollectionRecord: Codable, Hashable {
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
    var source: String?
    var sourceKey: String?

    enum CodingKeys: String, CodingKey {
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
        case source
        case sourceKey = "source_key"
    }
}

struct CollectionItemRecord: Codable, Hashable {
    static let databaseTableName = "collection_items"

    var itemId: String
    var collectionId: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case collectionId = "collection_id"
        case createdAt = "created_at"
    }
}

// MARK: - Property System

struct PropertyRecord: Codable, Hashable {
    static let databaseTableName = "properties"

    var id: String
    var name: String
    var type: String          // "multi_select", "single_select", "number", "text"
    var icon: String
    var position: Int
    var isSystem: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type, icon, position
        case isSystem = "is_system"
    }
}

struct PropertyOptionRecord: Codable, Hashable {
    static let databaseTableName = "property_options"

    var id: String
    var propertyId: String
    var name: String
    var colorHex: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case id
        case propertyId = "property_id"
        case name
        case colorHex = "color_hex"
        case position
    }
}

struct ItemPropertyValueRecord: Codable, Hashable {
    static let databaseTableName = "item_property_values"

    var id: String
    var itemId: String
    var propertyId: String
    var optionId: String?
    var textValue: String?

    enum CodingKeys: String, CodingKey {
        case id
        case itemId = "item_id"
        case propertyId = "property_id"
        case optionId = "option_id"
        case textValue = "text_value"
    }
}

// MARK: - Conversations


// MARK: - Citations

struct CitationRecord: Codable, Hashable {
    static let databaseTableName = "citations"

    var itemId: String          // PK, FK → items.id
    var cslJson: String         // Full CSL JSON string
    var cslType: String         // "article-journal", "book", etc.
    var doi: String?
    var year: Int?
    var containerTitle: String?
    var abstract: String?
    var pmid: String?
    var arxivId: String?
    var isbn: String?
    var issn: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case cslJson = "csl_json"
        case cslType = "csl_type"
        case doi, year
        case containerTitle = "container_title"
        case abstract
        case pmid
        case arxivId = "arxiv_id"
        case isbn, issn
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Annotations




