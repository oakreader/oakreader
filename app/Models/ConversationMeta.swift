import Foundation

/// Conversation metadata — stored in SQLite via GRDB.
/// The actual chat turns are stored as JSONL files in ~/OakReader/chats/.
struct ConversationMeta: Identifiable, Hashable {
    let id: UUID
    var title: String
    var itemId: UUID?
    var createdAt: Date
    var lastMessageAt: Date
    var messageCount: Int
    /// Short teaser of the conversation (first user message), for the history list's
    /// second line. Populated lazily by `ConversationService` from the JSONL file.
    var snippet: String

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        itemId: UUID? = nil,
        createdAt: Date = Date(),
        lastMessageAt: Date = Date(),
        messageCount: Int = 0,
        snippet: String = ""
    ) {
        self.id = id
        self.title = title
        self.itemId = itemId
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.snippet = snippet
    }

    init(record: ConversationRecord, snippet: String = "") {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.title = record.title
        self.itemId = record.itemId.flatMap { UUID(uuidString: $0) }
        self.createdAt = Date(iso8601String: record.createdAt) ?? Date()
        self.lastMessageAt = Date(iso8601String: record.updatedAt) ?? Date()
        self.messageCount = record.messageCount
        self.snippet = snippet
    }
}
