import Foundation

enum ItemType: String, Codable {
    case pdf
    case webSnapshot
    case embed

    var icon: String {
        switch self {
        case .pdf: return "doc.fill"
        case .webSnapshot: return "globe"
        case .embed: return "play.rectangle"
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .webSnapshot: return "Web"
        case .embed: return "Embed"
        }
    }
}
