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
    var id = UUID()
    var field: FilterField
    var op: FilterOperator
    var value: String
    var propertyId: String?
}

enum FilterField: String, Codable, CaseIterable {
    case itemType = "item_type"
    case lastOpenedAt = "last_opened_at"
    case createdAt = "created_at"
    case title
    case author
    case property
}

enum FilterOperator: String, Codable, CaseIterable {
    case eq
    case neq
    case contains
    case withinDays = "within_days"
    case hasOption = "has_option"
}
