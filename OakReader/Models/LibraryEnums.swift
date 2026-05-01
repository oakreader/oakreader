import Foundation

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

enum SystemCollectionID {
    static let inbox       = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let allItems    = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let recent      = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let pdfs        = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let webSnapshots = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    static let videos      = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!

    static let all: [UUID] = [inbox, allItems, recent, pdfs, webSnapshots, videos]
}

// MARK: - Local user ID

/// Default user ID for Phase 1 (local-only). Will become a real user ID in Phase 2 (sync).
let localUserId = "local"
