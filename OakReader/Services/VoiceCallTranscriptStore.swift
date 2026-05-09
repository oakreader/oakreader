import Foundation
import VoiceAgentKit

/// Persists voice call transcripts as JSONL files (one `VoiceCallTurn` per line).
///
/// Storage layout:
/// ```
/// ~/OakReader/calls/
///   {callId}/
///     transcript.jsonl
///     audio/
///       turn-0-user.caf
///       turn-0-agent.caf
///       ...
/// ```
struct VoiceCallTranscriptStore {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Paths

    static var baseDirectory: URL {
        CatalogDatabase.callsDirectory
    }

    static func callDirectory(callId: String) -> URL {
        CatalogDatabase.callDirectory(callId: callId)
    }

    static func transcriptURL(callId: String) -> URL {
        CatalogDatabase.callTranscriptURL(callId: callId)
    }

    static func audioURL(callId: String, turnIndex: Int, role: String) -> URL {
        CatalogDatabase.callAudioURL(callId: callId, turnIndex: turnIndex, role: role)
    }

    // MARK: - Write

    func appendTurn(_ turn: VoiceCallTurn, callId: String) throws {
        let dir = Self.callDirectory(callId: callId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = Self.transcriptURL(callId: callId)
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

    // MARK: - Read

    func loadTurns(callId: String) throws -> [VoiceCallTurn] {
        let url = Self.transcriptURL(callId: callId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let content = try String(contentsOf: url, encoding: .utf8)
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(VoiceCallTurn.self, from: data)
            }
    }

    // MARK: - Delete

    /// Remove the entire call directory (transcript + audio).
    func deleteCall(callId: String) {
        let dir = Self.callDirectory(callId: callId)
        try? FileManager.default.removeItem(at: dir)
    }
}
