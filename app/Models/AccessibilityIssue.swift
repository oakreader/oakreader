import Foundation

struct AccessibilityIssue: Identifiable {
    let id: UUID
    var severity: Severity
    var message: String
    var pageIndex: Int?
    var suggestion: String?

    enum Severity: String {
        case error
        case warning
        case info

        var label: String { rawValue.capitalized }
    }

    init(severity: Severity, message: String, pageIndex: Int? = nil, suggestion: String? = nil) {
        self.id = UUID()
        self.severity = severity
        self.message = message
        self.pageIndex = pageIndex
        self.suggestion = suggestion
    }
}
