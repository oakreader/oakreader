import Foundation

extension CatalogDatabase {
    /// ~/OakReader/
    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader", isDirectory: true)
    }

    /// ~/OakReader/storage/
    static var storageDirectory: URL {
        dataDirectory.appendingPathComponent("storage", isDirectory: true)
    }

    /// ~/OakReader/vectors/
    static var vectorsDirectory: URL {
        dataDirectory.appendingPathComponent("vectors", isDirectory: true)
    }

    /// ~/OakReader/semantic.db — regenerable chunk text + metadata + FTS5
    static var semanticDatabaseURL: URL {
        dataDirectory.appendingPathComponent("semantic.db")
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
