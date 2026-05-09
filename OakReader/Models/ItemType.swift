import Foundation

enum ItemType: String, Codable {
    case pdf
    case webSnapshot
    case embed
    case markdown

    var icon: String {
        switch self {
        case .pdf: return "doc.fill"
        case .webSnapshot: return "globe"
        case .embed: return "play.rectangle"
        case .markdown: return "doc.text"
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .webSnapshot: return "Web"
        case .embed: return "Embed"
        case .markdown: return "Note"
        }
    }
}
