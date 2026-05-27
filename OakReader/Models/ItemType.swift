import Foundation

/// The format of an attachment's content — what the content IS.
/// Aligned with Zotero's `attachmentContentType` (MIME-based), simplified to an enum.
enum ContentType: String, Codable {
    case pdf        // application/pdf
    case html       // text/html (saved web page snapshots)
    case markdown   // text/markdown
    case audio      // audio/*
    case link       // generic web link / bookmark (loaded on demand)

    var icon: String {
        switch self {
        case .pdf: return "doc.fill"
        case .html: return "globe"
        case .markdown: return "doc.text"
        case .audio: return "headphones"
        case .link: return "link"
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .html: return "Web"
        case .markdown: return "Note"
        case .audio: return "Audio"
        case .link: return "Bookmark"
        }
    }
}

/// How an attachment's content is stored/accessed.
/// Aligned with Zotero's `attachmentLinkMode`.
enum LinkMode: String, Codable {
    case importedFile   // File stored in OakReader's managed storage
    case importedURL    // URL content snapshot saved locally (web page saved offline)
    case linkedURL      // External URL loaded on demand (YouTube, link embed, etc.)
}
