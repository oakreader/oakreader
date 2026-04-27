import Foundation

enum DocumentType: String, Codable {
    case pdf
    case webSnapshot
    case youtubeVideo
    case podcast

    var icon: String {
        switch self {
        case .pdf: return "doc.fill"
        case .webSnapshot: return "globe"
        case .youtubeVideo: return "play.rectangle.fill"
        case .podcast: return "headphones"
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .webSnapshot: return "Web Snapshot"
        case .youtubeVideo: return "YouTube Video"
        case .podcast: return "Podcast"
        }
    }
}
