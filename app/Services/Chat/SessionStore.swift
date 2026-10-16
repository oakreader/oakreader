import Foundation

/// Reads chat transcripts. Each is a pi session file the core writes; see
/// `PiSession`. The shell never writes one. It deletes a file only when the
/// user deletes the conversation.
actor SessionStore {
    private let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    private func fileURL(for sessionId: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(sessionId.uuidString).jsonl")
    }

    func loadTurns(sessionId: UUID) throws -> [Turn] {
        PiSession.turns(from: try PiSession.read(fileURL(for: sessionId)))
    }

    func deleteSession(_ sessionId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
        for url in CatalogDatabase.legacyChatFiles(sessionId: sessionId) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
