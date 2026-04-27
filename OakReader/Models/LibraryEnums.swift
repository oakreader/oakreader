import Foundation

// MARK: - Tag Colors

enum TagColor: String, CaseIterable, Identifiable {
    case red, orange, gray, green, teal, blue, indigo, purple, plum

    var id: String { rawValue }

    var hex: String {
        switch self {
        case .red:    return "FF6666"
        case .orange: return "FF8C19"
        case .gray:   return "999999"
        case .green:  return "5FB236"
        case .teal:   return "009980"
        case .blue:   return "2EA8E5"
        case .indigo: return "576DD9"
        case .purple: return "A28AE5"
        case .plum:   return "A6507B"
        }
    }
}

// MARK: - Enums

enum SyncStatus: String, Codable {
    case local
    case synced
    case pendingUpload
    case pendingDownload
    case conflict
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case dateAdded = "Date Added"
    case dateOpened = "Last Opened"
    case title = "Title"
    case author = "Author"
    case fileSize = "File Size"

    var id: String { rawValue }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case inbox = "Inbox"
    case all = "All Items"
    case recentlyAdded = "Recently Added"
    case favorites = "Favorites"
    case pdfs = "PDFs"
    case webSnapshots = "Web Snapshots"
    case videos = "Videos"
    case podcasts = "Podcasts"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .inbox: return "tray.and.arrow.down"
        case .all: return "books.vertical"
        case .recentlyAdded: return "clock"
        case .favorites: return "star"
        case .pdfs: return "doc.fill"
        case .webSnapshots: return "globe"
        case .videos: return "play.rectangle.fill"
        case .podcasts: return "headphones"
        }
    }
}

// MARK: - Local user ID

/// Default user ID for Phase 1 (local-only). Will become a real user ID in Phase 2 (sync).
let localUserId = "local"
