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

    /// ~/OakReader/semantic.sqlite — regenerable chunk text + metadata + FTS5
    static var semanticDatabaseURL: URL {
        dataDirectory.appendingPathComponent("semantic.sqlite")
    }

    /// ~/OakReader/semantic.usearch — HNSW vector index (regenerable)
    static var semanticIndexURL: URL {
        dataDirectory.appendingPathComponent("semantic.usearch")
    }

    /// ~/OakReader/logs/
    static var logsDirectory: URL {
        dataDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// ~/OakReader/notes/
    static var notesDirectory: URL {
        dataDirectory.appendingPathComponent("notes", isDirectory: true)
    }

    /// ~/OakReader/notes/attachments/
    static var notesAttachmentsDirectory: URL {
        notesDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    /// Centralized note file: ~/OakReader/notes/{noteId}.md
    static func noteFileURL(noteId: UUID) -> URL {
        notesDirectory.appendingPathComponent("\(noteId.uuidString).md")
    }

    /// ~/OakReader/notes/attachments/{noteId}/
    static func noteAttachmentDirectory(noteId: UUID) -> URL {
        notesAttachmentsDirectory.appendingPathComponent(noteId.uuidString, isDirectory: true)
    }

    /// ~/OakReader/notes/attachments/{noteId}/{fileName}
    static func noteAttachmentURL(noteId: UUID, fileName: String) -> URL {
        noteAttachmentDirectory(noteId: noteId).appendingPathComponent(fileName)
    }

    /// ~/OakReader/agent/
    static var agentDirectory: URL {
        dataDirectory.appendingPathComponent("agent", isDirectory: true)
    }

    /// ~/OakReader/agent/USER.md
    static var agentUserFileURL: URL {
        agentDirectory.appendingPathComponent("USER.md")
    }

    /// ~/OakReader/agent/MEMORY.md
    static var agentMemoryFileURL: URL {
        agentDirectory.appendingPathComponent("MEMORY.md")
    }

    /// ~/OakReader/agent/memory/ — learning logs (legacy)
    static var agentMemoryLogsDirectory: URL {
        agentDirectory.appendingPathComponent("memory", isDirectory: true)
    }


    /// ~/OakReader/agent/memory/YYYY-MM-DD.jsonl — daily learning log (one JSON per line)
    static func agentDailyLogURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = formatter.string(from: date) + ".jsonl"
        return agentMemoryLogsDirectory.appendingPathComponent(filename)
    }

    /// ~/OakReader/agent/memory/YYYY-MM.md — monthly summary (markdown, curated)
    static func agentMonthlyLogURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let filename = formatter.string(from: date) + ".md"
        return agentMemoryLogsDirectory.appendingPathComponent(filename)
    }

    /// ~/OakReader/agent/memory/YYYY.md — yearly trajectory (markdown, curated)
    static func agentYearlyLogURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        let filename = formatter.string(from: date) + ".md"
        return agentMemoryLogsDirectory.appendingPathComponent(filename)
    }

    /// ~/OakReader/chats/
    static var chatsDirectory: URL {
        dataDirectory.appendingPathComponent("chats", isDirectory: true)
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
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notesAttachmentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatAttachmentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentMemoryLogsDirectory, withIntermediateDirectories: true)
        bootstrapAgentFiles()
    }

    /// Copy USER.md and MEMORY.md templates into ~/OakReader/agent/ on first launch.
    private static func bootstrapAgentFiles() {
        let fm = FileManager.default
        let templates: [(resource: String, destination: URL)] = [
            ("USER", agentUserFileURL),
            ("MEMORY", agentMemoryFileURL)
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

    /// Transcript file URL for an embed attachment.
    static func attachmentTranscriptURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("transcript.txt")
    }

    /// Chapters JSON URL for an embed attachment.
    static func attachmentChaptersURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("chapters.json")
    }

    /// Highlights JSON URL for an embed attachment.
    static func attachmentHighlightsURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("highlights.json")
    }

    /// Summary JSON URL for an audio recording attachment.
    static func attachmentSummaryURL(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent("summary.json")
    }
}
