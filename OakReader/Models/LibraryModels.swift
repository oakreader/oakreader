import Foundation
import SwiftData
import SwiftUI

// MARK: - Library Item

@Model
final class PDFLibraryItem {
    @Attribute(.unique) var id: UUID

    // File reference — store bookmark data for security-scoped access
    var fileBookmarkData: Data?
    var fileName: String
    var filePath: String?  // Fallback when bookmark creation fails (e.g. debug builds)

    // Metadata
    var title: String
    var author: String
    var dateAdded: Date
    var dateLastOpened: Date?
    var pageCount: Int
    var fileSize: Int64

    // Organization
    var isFavorite: Bool
    @Relationship(inverse: \PDFCollection.items)
    var collections: [PDFCollection]
    var tags: [PDFTag]

    // Cover
    var coverImageData: Data?

    // Future: cloud sync
    var syncStatus: SyncStatus
    var remoteIdentifier: String?

    init(
        fileName: String,
        title: String = "",
        author: String = "",
        pageCount: Int = 0,
        fileSize: Int64 = 0
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.title = title.isEmpty ? fileName : title
        self.author = author
        self.dateAdded = Date()
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.isFavorite = false
        self.collections = []
        self.tags = []
        self.syncStatus = .local
    }

    // MARK: - Security-Scoped Bookmark

    func resolveFileURL() -> URL? {
        // Try security-scoped bookmark first
        if let bookmarkData = fileBookmarkData {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    self.fileBookmarkData = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }
                return url
            } catch {
                NSLog("[Library] bookmark resolve failed for \(title): \(error)")
            }
        }

        // Fallback: use stored file path
        if let filePath, FileManager.default.fileExists(atPath: filePath) {
            return URL(fileURLWithPath: filePath)
        }

        NSLog("[Library] resolveFileURL: no bookmark or path for \(title)")
        return nil
    }

    func setFileURL(_ url: URL) {
        // Always store the path as fallback
        self.filePath = url.path
        self.fileName = url.lastPathComponent

        // Try to create security-scoped bookmark
        do {
            self.fileBookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            NSLog("[Library] bookmark creation failed for \(url.lastPathComponent): \(error). Using path fallback.")
            self.fileBookmarkData = nil
        }
    }
}

// MARK: - Collection

@Model
final class PDFCollection {
    @Attribute(.unique) var id: UUID
    var name: String
    var icon: String
    var sortOrder: Int
    var items: [PDFLibraryItem]

    // Subcollection support
    var parent: PDFCollection?
    @Relationship(deleteRule: .cascade, inverse: \PDFCollection.parent)
    var subcollections: [PDFCollection]

    init(name: String, icon: String = "folder", sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.sortOrder = sortOrder
        self.items = []
        self.subcollections = []
    }
}

// MARK: - Tag

@Model
final class PDFTag {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    var position: Int
    @Relationship(inverse: \PDFLibraryItem.tags)
    var items: [PDFLibraryItem]

    init(name: String, colorHex: String, position: Int = 0) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.position = position
        self.items = []
    }
}

// MARK: - Tag Colors (Zotero palette)

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
    case all = "All PDFs"
    case recentlyAdded = "Recently Added"
    case favorites = "Favorites"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "books.vertical"
        case .recentlyAdded: return "clock"
        case .favorites: return "star"
        }
    }
}
