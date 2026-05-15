import Foundation
import GRDB

struct VoiceCallService {
    let database: CatalogDatabase

    // MARK: - Voice Calls Directory

    static var voiceCallsDirectory: URL {
        VoiceCallTranscriptStore.baseDirectory
    }

    static func transcriptURL(callId: String) -> URL {
        VoiceCallTranscriptStore.transcriptURL(callId: callId)
    }

    // MARK: - Calls

    func fetchAllCalls() throws -> [VoiceCall] {
        try database.dbQueue.read { db in
            let records = try VoiceCallRecord
                .order(VoiceCallRecord.CodingKeys.updatedAt.desc)
                .fetchAll(db)
            return records.map { VoiceCall(record: $0) }
        }
    }

    @discardableResult
    func createCall() throws -> VoiceCall {
        let now = Date().iso8601String
        var record = VoiceCallRecord(
            id: UUID().uuidString,
            title: "",
            turnCount: 0,
            durationSeconds: 0,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }
        let callDir = VoiceCallTranscriptStore.callDirectory(callId: record.id)
        try FileManager.default.createDirectory(at: callDir, withIntermediateDirectories: true)
        return VoiceCall(record: record)
    }

    func updateCall(id: UUID, title: String, turnCount: Int, durationSeconds: Double) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE voice_calls SET title = ?, turn_count = ?, duration_seconds = ?, updated_at = ? WHERE id = ?",
                arguments: [title, turnCount, durationSeconds, now, id.uuidString]
            )
        }
    }

    func deleteCall(id: UUID) throws {
        VoiceCallTranscriptStore().deleteCall(callId: id.uuidString)
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM voice_calls WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
