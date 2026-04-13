import Foundation
import SwiftData

@Model
final class ChatSessionMeta {
    @Attribute(.unique) var id: UUID
    var title: String
    var documentFileName: String?
    var createdAt: Date
    var lastMessageAt: Date
    var messageCount: Int

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        documentFileName: String? = nil,
        createdAt: Date = Date(),
        lastMessageAt: Date = Date(),
        messageCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.documentFileName = documentFileName
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
    }
}
