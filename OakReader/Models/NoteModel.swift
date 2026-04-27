import Foundation

/// View-facing note model, constructed from NoteRecord.
/// Content is loaded on demand from the .md file on disk.
struct Note: Identifiable, Hashable {
    let id: UUID
    var title: String
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    /// Display title: returns title if non-empty, else "New Note".
    var displayTitle: String {
        title.isEmpty ? "New Note" : title
    }

    // MARK: - Record conversion

    init(record: NoteRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.title = record.title
        self.isPinned = record.isPinned
        self.createdAt = Date(iso8601String: record.createdAt) ?? Date()
        self.updatedAt = Date(iso8601String: record.updatedAt) ?? Date()
    }

    init(id: UUID = UUID(), title: String = "", isPinned: Bool = false,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
