import Foundation

// MARK: - Enums

enum SyncStatus: String, Codable {
    case local
    case synced
    case pendingUpload
    case pendingDownload
    case conflict
}

enum ProcessingStatus: String, Codable {
    case none
    case transcribing
    case transcribed
    case failed
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case dateAdded = "Date Added"
    case dateOpened = "Last Opened"
    case title = "Title"
    case author = "Author"
    case fileSize = "File Size"

    var id: String { rawValue }
}

/// Middle-pane presentation for the Library: Finder-style list vs. masonry card grid.
enum LibraryViewMode: String, CaseIterable, Identifiable {
    case list
    case card

    var id: String { rawValue }

    /// SF Symbol for the segmented toggle.
    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .card: return "square.grid.2x2"
        }
    }
}

enum SystemCollectionID {
    static let readingList  = UUID(uuidString: "00000000-0000-0000-0000-00000000000E")!
    static let allItems     = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let pdfs         = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let html         = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    static let embeds       = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    static let recentlyRead = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    static let duplicates   = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let bin          = UUID(uuidString: "00000000-0000-0000-0000-00000000000F")!

    static let all: [UUID] = [readingList, allItems, recentlyRead, pdfs, html, embeds, duplicates, bin]
}

enum SystemPropertyID {
    static let tags   = UUID(uuidString: "00000000-0000-0000-0001-000000000001")!
    static let status = UUID(uuidString: "00000000-0000-0000-0001-000000000002")!
    static let rating = UUID(uuidString: "00000000-0000-0000-0001-000000000003")!
}

enum SystemStatusOptionID {
    static let toRead   = UUID(uuidString: "00000000-0000-0000-0002-000000000001")!
    static let reading  = UUID(uuidString: "00000000-0000-0000-0002-000000000002")!
    static let finished = UUID(uuidString: "00000000-0000-0000-0002-000000000003")!
}

// MARK: - Local user ID

/// Default user ID for Phase 1 (local-only). Will become a real user ID in Phase 2 (sync).
let localUserId = "local"
