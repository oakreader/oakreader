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
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.skill = skill
        self.error = error
        self.attachments = attachments
    }
}

// MARK: - Chat Attachment

public struct ChatAttachment: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: AttachmentType
    public let label: String
    public let textContent: String?
    /// Relative file path for image attachments (stored on disk, not inline).
    /// Path is relative to the session's attachments directory.
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
