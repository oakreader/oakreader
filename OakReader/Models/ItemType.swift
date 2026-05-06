import Foundation

enum ItemType: String, Codable {
    case pdf
    case webSnapshot
    case embed
    case epub

    var icon: String {
        switch self {
        case .pdf: return "doc.fill"
        case .webSnapshot: return "globe"
        case .embed: return "play.rectangle"
        case .epub: return "book.fill"
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .webSnapshot: return "Web"
        case .embed: return "Embed"
        case .epub: return "EPUB"
        }
    }
}
