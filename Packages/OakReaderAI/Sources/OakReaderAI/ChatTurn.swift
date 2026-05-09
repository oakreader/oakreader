import Foundation

// MARK: - Chat Turn

public struct ChatTurn: Identifiable, Codable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public var content: String
    public let timestamp: Date
    public var isStreaming: Bool
    public var skill: String?
    public var error: String?
    public var attachments: [ChatAttachment]
    public var toolUses: [ToolUseRecord]

    public enum ChatRole: String, Codable, Sendable {
        case user, assistant, system
    }

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        skill: String? = nil,
        error: String? = nil,
        attachments: [ChatAttachment] = [],
        toolUses: [ToolUseRecord] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.skill = skill
        self.error = error
        self.attachments = attachments
        self.toolUses = toolUses
    }

    // Custom Decodable for backward compatibility with old JSONL files without toolUses
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        skill = try container.decodeIfPresent(String.self, forKey: .skill)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        toolUses = try container.decodeIfPresent([ToolUseRecord].self, forKey: .toolUses) ?? []
    }
}

// MARK: - Chat Attachment

public struct ChatAttachment: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: AttachmentType
    public let label: String
    public let textContent: String?
    /// Relative file path for image attachments (stored on disk, not inline).
    /// Path is relative to `chats/attachments/{sessionId}/`.
    public let filePath: String?
    /// Inline image data — used only for in-memory/pending attachments, not persisted in JSONL.
    public let imageData: Data?
    public let pageIndex: Int?

    public enum AttachmentType: String, Codable, Sendable {
        case textSelection
        case imageCapture
    }

    public init(
        id: UUID = UUID(),
        type: AttachmentType,
        label: String,
        textContent: String? = nil,
        filePath: String? = nil,
        imageData: Data? = nil,
        pageIndex: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.textContent = textContent
        self.filePath = filePath
        self.imageData = imageData
        self.pageIndex = pageIndex
    }
}
