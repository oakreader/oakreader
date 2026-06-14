import Foundation

extension CatalogDatabase {
    /// ~/OakReader/ (Release) or ~/OakReader-Dev/ (Debug)
    static var dataDirectory: URL {
        #if DEBUG
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader-Dev", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader", isDirectory: true)
        #endif
    }

    /// ~/OakReader/storage/
    static var storageDirectory: URL {
        dataDirectory.appendingPathComponent("storage", isDirectory: true)
    }

    /// ~/OakReader/search.sqlite — regenerable chunk text + metadata + FTS5
    static var searchDatabaseURL: URL {
        dataDirectory.appendingPathComponent("search.sqlite")
    }

    /// ~/OakReader/logs/
    static var logsDirectory: URL {
        dataDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// ~/OakReader/agent/
    static var agentDirectory: URL {
        dataDirectory.appendingPathComponent("agent", isDirectory: true)
    }

    /// ~/OakReader/agent/USER.md
    static var agentUserFileURL: URL {
        agentDirectory.appendingPathComponent("USER.md")
    }

    /// ~/OakReader/agent/VOICE.md
    static var agentVoiceFileURL: URL {
        agentDirectory.appendingPathComponent("VOICE.md")
    }

    /// ~/OakReader/agent/profile.jsonl — user memory as discrete facts (one JSON per line).
    static var agentProfileFactsURL: URL {
        agentDirectory.appendingPathComponent("profile.jsonl")
    }

    /// ~/OakReader/agent/memory-log.jsonl — append-only audit log of memory operations.
    static var agentMemoryLogURL: URL {
        agentDirectory.appendingPathComponent("memory-log.jsonl")
    }

    /// ~/OakReader/chats/
    static var chatsDirectory: URL {
        dataDirectory.appendingPathComponent("chats", isDirectory: true)
    }

    /// ~/OakReader/chats/briefs/ — per-document conversation briefs (auto-summarized
    /// continuity notes, one markdown file per item). Injected only when that item is open.
    static var chatBriefsDirectory: URL {
        chatsDirectory.appendingPathComponent("briefs", isDirectory: true)
    }

    /// ~/OakReader/chats/briefs/{itemId}.md — legacy prose brief (migration source).
    static func chatBriefURL(itemId: String) -> URL {
        chatBriefsDirectory.appendingPathComponent("\(itemId).md")
    }

    /// ~/OakReader/chats/briefs/{itemId}.jsonl — item memory as discrete facts.
    static func chatBriefFactsURL(itemId: String) -> URL {
        chatBriefsDirectory.appendingPathComponent("\(itemId).jsonl")
    }

    /// ~/OakReader/chats/attachments/
    static var chatAttachmentsDirectory: URL {
        chatsDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    /// ~/OakReader/chats/{sessionId}.jsonl
    static func chatFileURL(sessionId: UUID) -> URL {
        chatsDirectory.appendingPathComponent("\(sessionId.uuidString).jsonl")
    }

    /// ~/OakReader/chats/attachments/{sessionId}/
    static func chatAttachmentDirectory(sessionId: UUID) -> URL {
        chatAttachmentsDirectory.appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    /// ~/OakReader/chats/attachments/{sessionId}/{fileName}
    static func chatAttachmentURL(sessionId: UUID, fileName: String) -> URL {
        chatAttachmentDirectory(sessionId: sessionId).appendingPathComponent(fileName)
    }

    static func createBaseDirectories() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatAttachmentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatBriefsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        bootstrapAgentFiles()
    }

    /// Copy USER.md and VOICE.md templates into ~/OakReader/agent/ on first launch.
    private static func bootstrapAgentFiles() {
        let fm = FileManager.default
        let templates: [(resource: String, destination: URL)] = [
            ("USER", agentUserFileURL),
            ("VOICE", agentVoiceFileURL)
        ]
        for template in templates {
            guard !fm.fileExists(atPath: template.destination.path) else { continue }
            if let bundleURL = Bundle.main.url(
                forResource: template.resource, withExtension: "md", subdirectory: "AgentTemplates"
            ), let content = try? String(contentsOf: bundleURL, encoding: .utf8) {
                try? content.write(to: template.destination, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Storage Key Generation

    /// Generate an 8-character random alphanumeric key.
    static func generateStorageKey() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    // MARK: - Item-Level Helpers

    /// Storage directory for a specific item: storage/{itemKey}/
    static func documentDirectory(storageKey: String) -> URL {
        storageDirectory.appendingPathComponent(storageKey, isDirectory: true)
    }

    // MARK: - Attachment-Level Helpers

    /// Attachment directory: storage/{itemKey}/attachments/{attachmentKey}/
    static func attachmentDirectory(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        documentDirectory(storageKey: itemStorageKey)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(attachmentStorageKey, isDirectory: true)
    }

    /// Attachment file URL: storage/{itemKey}/attachments/{attachmentKey}/{fileName}
    static func attachmentFileURL(itemStorageKey: String, attachmentStorageKey: String, fileName: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent(fileName)
    }

    /// Cover image URL for an attachment: storage/{itemKey}/attachments/{attachmentKey}/cover.webp
    static func attachmentCoverURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("cover.webp")
    }

    /// Metadata JSON URL for an embed attachment.
    static func attachmentMetadataURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("metadata.json")
    }

    /// Transcript file URL for an attachment (audio recordings).
    static func attachmentTranscriptURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("transcript.txt")
    }

    /// Summary JSON URL for an audio recording attachment.
    static func attachmentSummaryURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("summary.json")
    }
}
