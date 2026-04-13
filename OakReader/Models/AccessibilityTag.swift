import Foundation

enum PDFTagType: String, CaseIterable, Identifiable {
    case document = "Document"
    case part = "Part"
    case section = "Sect"
    case heading1 = "H1"
    case heading2 = "H2"
    case heading3 = "H3"
    case heading4 = "H4"
    case heading5 = "H5"
    case heading6 = "H6"
    case paragraph = "P"
    case list = "L"
    case listItem = "LI"
    case table = "Table"
    case tableRow = "TR"
    case tableHeaderCell = "TH"
    case tableDataCell = "TD"
    case figure = "Figure"
    case formula = "Formula"
    case form = "Form"
    case span = "Span"
    case link = "Link"
    case note = "Note"
    case reference = "Reference"
    case blockQuote = "BlockQuote"
    case caption = "Caption"
    case artifact = "Artifact"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .document: return "Document"
        case .part: return "Part"
        case .section: return "Section"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .heading4: return "Heading 4"
        case .heading5: return "Heading 5"
        case .heading6: return "Heading 6"
        case .paragraph: return "Paragraph"
        case .list: return "List"
        case .listItem: return "List Item"
        case .table: return "Table"
        case .tableRow: return "Table Row"
        case .tableHeaderCell: return "Table Header"
        case .tableDataCell: return "Table Cell"
        case .figure: return "Figure"
        case .formula: return "Formula"
        case .form: return "Form"
        case .span: return "Span"
        case .link: return "Link"
        case .note: return "Note"
        case .reference: return "Reference"
        case .blockQuote: return "Block Quote"
        case .caption: return "Caption"
        case .artifact: return "Artifact"
        }
    }
}

struct AccessibilityTagNode: Identifiable {
    let id: UUID
    var tagType: PDFTagType
    var alternativeText: String?
    var actualText: String?
    var pageIndex: Int?
    var bounds: CGRect?
    var children: [AccessibilityTagNode]

    init(tagType: PDFTagType, pageIndex: Int? = nil, bounds: CGRect? = nil) {
        self.id = UUID()
        self.tagType = tagType
        self.alternativeText = nil
        self.actualText = nil
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.children = []
    }
}

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
