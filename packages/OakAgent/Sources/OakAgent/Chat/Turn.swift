import Foundation

// MARK: - Turn

public struct Turn: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: Role
    public var content: String
    public let timestamp: Date
    public var isStreaming: Bool
    public var metadata: [String: String]
    public var error: String?
    public var attachments: [TurnAttachment]
    public var toolUses: [ToolUseRecord]
    /// Extended thinking content from reasoning models.
    public var thinking: String?

    public enum Role: String, Codable, Sendable {
        case user, assistant, system
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        metadata: [String: String] = [:],
        error: String? = nil,
        attachments: [TurnAttachment] = [],
        toolUses: [ToolUseRecord] = [],
        thinking: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.metadata = metadata
        self.error = error
        self.attachments = attachments
        self.toolUses = toolUses
        self.thinking = thinking
    }

    // Custom Decodable for backward compatibility with old JSONL files
    // that may have `skill` instead of `metadata`, or missing fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        attachments = try container.decodeIfPresent([TurnAttachment].self, forKey: .attachments) ?? []
        toolUses = try container.decodeIfPresent([ToolUseRecord].self, forKey: .toolUses) ?? []
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)

        // Backward compat: decode `metadata` dict, or fall back to legacy `skill` string
        if let meta = try container.decodeIfPresent([String: String].self, forKey: .metadata) {
            metadata = meta
        } else if let skill = try container.decodeIfPresent(String.self, forKey: .skill) {
            metadata = ["skill": skill]
        } else {
            metadata = [:]
        }
    }

    // Coding keys include legacy `skill` for backward-compatible decoding
    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, isStreaming, metadata, error, attachments, toolUses, skill, thinking
    }

    // Custom encode to only write `metadata` (not the legacy `skill` key)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(toolUses, forKey: .toolUses)
        try container.encodeIfPresent(thinking, forKey: .thinking)
    }
}

// MARK: - Turn Attachment

public struct TurnAttachment: Identifiable, Codable, Equatable, Sendable {
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
