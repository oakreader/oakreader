import Foundation

/// Persists chat turns as JSONL files (one JSON object per line).
/// All sessions are stored in the provided base directory.
public actor ChatSessionStore {
    private let baseDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Initialize with a base directory for session files.
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - File path

    private func fileURL(for sessionId: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(sessionId.uuidString).jsonl")
    }

    private func attachmentDirectory(for sessionId: UUID) -> URL {
        baseDirectory
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    // MARK: - Write

    public func appendTurn(_ turn: ChatTurn, sessionId: UUID) throws {
        let url = fileURL(for: sessionId)
        let data = try encoder.encode(persistedTurn(turn, sessionId: sessionId))
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
            .map { hydratedTurn($0, sessionId: sessionId) }
    }

    // MARK: - Delete

    public func deleteSession(_ sessionId: UUID) {
        let url = fileURL(for: sessionId)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: attachmentDirectory(for: sessionId))
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent("\(sessionId.uuidString)_attachments"))
    }

    // MARK: - Internal

    private func writeAll(_ turns: [ChatTurn], sessionId: UUID) throws {
        let url = fileURL(for: sessionId)
        let lines = try turns.map { turn -> String in
            let data = try encoder.encode(persistedTurn(turn, sessionId: sessionId))
            return String(data: data, encoding: .utf8) ?? ""
        }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func persistedTurn(_ turn: ChatTurn, sessionId: UUID) throws -> ChatTurn {
        let attachments = try turn.attachments.map { attachment -> ChatAttachment in
            guard attachment.type == .imageCapture,
                  let imageData = attachment.imageData else {
                return attachment
            }

            let fileName = "\(attachment.id.uuidString).png"
            let dir = attachmentDirectory(for: sessionId)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                try imageData.write(to: url, options: .atomic)
            }

            return ChatAttachment(
                id: attachment.id,
                type: attachment.type,
                label: attachment.label,
                textContent: attachment.textContent,
                filePath: fileName,
                imageData: nil,
                pageIndex: attachment.pageIndex
            )
        }

        return ChatTurn(
            id: turn.id,
            role: turn.role,
            content: turn.content,
            timestamp: turn.timestamp,
            isStreaming: turn.isStreaming,
            skill: turn.skill,
            error: turn.error,
            attachments: attachments,
            toolUses: turn.toolUses
        )
    }

    private func hydratedTurn(_ turn: ChatTurn, sessionId: UUID) -> ChatTurn {
        let attachments = turn.attachments.map { attachment -> ChatAttachment in
            guard attachment.type == .imageCapture,
                  attachment.imageData == nil,
                  let filePath = attachment.filePath else {
                return attachment
            }

            let url = attachmentDirectory(for: sessionId).appendingPathComponent(filePath)
            let imageData = try? Data(contentsOf: url)
            return ChatAttachment(
                id: attachment.id,
                type: attachment.type,
                label: attachment.label,
                textContent: attachment.textContent,
                filePath: filePath,
                imageData: imageData,
                pageIndex: attachment.pageIndex
            )
        }

        return ChatTurn(
            id: turn.id,
            role: turn.role,
            content: turn.content,
            timestamp: turn.timestamp,
            isStreaming: turn.isStreaming,
            skill: turn.skill,
            error: turn.error,
            attachments: attachments,
            toolUses: turn.toolUses
        )
    }
}
