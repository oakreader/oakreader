import Foundation

/// Chat session metadata — stored in SQLite via GRDB (no longer SwiftData).
/// The actual chat turns are stored as JSONL files in the document's sessions/ directory.
struct ChatSessionMeta: Identifiable, Hashable {
    let id: UUID
    var title: String
    var documentId: UUID
    var createdAt: Date
    var lastMessageAt: Date
    var messageCount: Int

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        documentId: UUID,
        createdAt: Date = Date(),
        lastMessageAt: Date = Date(),
        messageCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.documentId = documentId
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
    }

    init(record: ChatSessionRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.title = record.title
        self.documentId = UUID(uuidString: record.documentId) ?? UUID()
        self.createdAt = Date(iso8601String: record.createdAt) ?? Date()
        self.lastMessageAt = Date(iso8601String: record.updatedAt) ?? Date()
        self.messageCount = record.messageCount
    }
}
