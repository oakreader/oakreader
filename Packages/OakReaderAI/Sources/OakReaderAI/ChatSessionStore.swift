import Foundation

/// Persists chat turns as JSONL files (one JSON object per line).
public actor ChatSessionStore {
    private let baseDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseDirectory = appSupport.appendingPathComponent("OakReader/ChatSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - File path

    private func fileURL(for sessionId: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(sessionId.uuidString).jsonl")
    }

    // MARK: - Write

    public func appendTurn(_ turn: ChatTurn, sessionId: UUID) throws {
        let url = fileURL(for: sessionId)
        let data = try encoder.encode(turn)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try line.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// Replaces the last turn (used to finalize a streaming assistant message).
    public func replaceLastTurn(_ turn: ChatTurn, sessionId: UUID) throws {
        var turns = try loadTurns(sessionId: sessionId)
        if let idx = turns.lastIndex(where: { $0.id == turn.id }) {
            turns[idx] = turn
        } else {
            turns.append(turn)
        }
        try writeAll(turns, sessionId: sessionId)
    }

    // MARK: - Read

    public func loadTurns(sessionId: UUID) throws -> [ChatTurn] {
        let url = fileURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let content = try String(contentsOf: url, encoding: .utf8)
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ChatTurn.self, from: data)
            }
    }

    // MARK: - Delete

    public func deleteSession(_ sessionId: UUID) {
        let url = fileURL(for: sessionId)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Internal

    private func writeAll(_ turns: [ChatTurn], sessionId: UUID) throws {
        let url = fileURL(for: sessionId)
        let lines = try turns.map { turn -> String in
            let data = try encoder.encode(turn)
            return String(data: data, encoding: .utf8) ?? ""
        }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
