import Foundation

// MARK: - Filter Rule Model

struct FilterRuleSet: Codable, Hashable {
    var match: MatchMode
    var conditions: [FilterCondition]

    enum MatchMode: String, Codable, CaseIterable {
        case all  // AND
        case any  // OR
    }
}

struct FilterCondition: Codable, Hashable, Identifiable {
    var id: UUID
    var field: FilterField
    var op: FilterOperator
    var value: String
    var propertyId: String?

    init(id: UUID = UUID(), field: FilterField, op: FilterOperator, value: String, propertyId: String? = nil) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
        self.propertyId = propertyId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.field = try container.decode(FilterField.self, forKey: .field)
        self.op = try container.decode(FilterOperator.self, forKey: .op)
        self.value = try container.decode(String.self, forKey: .value)
        self.propertyId = try container.decodeIfPresent(String.self, forKey: .propertyId)
    }
}

enum FilterField: String, Codable, CaseIterable {
    case itemType = "item_type"
    case lastOpenedAt = "last_opened_at"
    case createdAt = "created_at"
    case title
    case author
    case property
    case source
}

enum FilterOperator: String, Codable, CaseIterable {
    case eq
    case neq
    case contains
    case withinDays = "within_days"
    case hasOption = "has_option"
}
