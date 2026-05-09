import Foundation
import GRDB

struct VoiceSpeakerService {
    let database: CatalogDatabase

    // MARK: - Voice Calls Directory

    static var voiceCallsDirectory: URL {
        VoiceCallTranscriptStore.baseDirectory
    }

    static func transcriptURL(callId: String) -> URL {
        VoiceCallTranscriptStore.transcriptURL(callId: callId)
    }

    // MARK: - Speakers

    func fetchAllSpeakers() throws -> [Speaker] {
        try database.dbQueue.read { db in
            let records = try SpeakerRecord
                .order(SpeakerRecord.CodingKeys.sortOrder.asc)
                .fetchAll(db)
            return records.map { Speaker(record: $0) }
        }
    }

    @discardableResult
    func createSpeaker(name: String, colorHex: String, language: String) throws -> Speaker {
        let now = Date().iso8601String
        let maxOrder = try database.dbQueue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) FROM speakers") ?? -1
        }
        var record = SpeakerRecord(
            id: UUID().uuidString,
            userId: localUserId,
            name: name,
            avatarColorHex: colorHex,
            ttsVoice: "",
            referenceAudioPath: "",
            referenceText: "",
            language: language,
            llmModel: "",
            sortOrder: maxOrder + 1,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }
        return Speaker(record: record)
    }

    func updateSpeaker(_ speaker: Speaker) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE speakers SET name = ?, avatar_color_hex = ?, tts_voice = ?,
                    reference_audio_path = ?, reference_text = ?, language = ?,
                    llm_model = ?, sort_order = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    speaker.name, speaker.avatarColorHex, speaker.ttsVoice,
                    speaker.referenceAudioPath, speaker.referenceText, speaker.language,
                    speaker.llmModel, speaker.sortOrder, now,
                    speaker.id.uuidString
                ]
            )
        }
    }

    func deleteSpeaker(id: UUID) throws {
        // Remove call directories (transcript + audio) first
        let calls = try fetchCalls(forSpeakerId: id)
        let store = VoiceCallTranscriptStore()
        for call in calls {
            store.deleteCall(callId: call.id.uuidString)
        }
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Calls

    func fetchCalls(forSpeakerId speakerId: UUID) throws -> [VoiceCall] {
        try database.dbQueue.read { db in
            let records = try VoiceCallRecord
                .filter(VoiceCallRecord.CodingKeys.speakerId == speakerId.uuidString)
                .order(VoiceCallRecord.CodingKeys.updatedAt.desc)
                .fetchAll(db)
            return records.map { VoiceCall(record: $0) }
        }
    }

    func fetchLastCall(forSpeakerId speakerId: UUID) throws -> VoiceCall? {
        try database.dbQueue.read { db in
            let record = try VoiceCallRecord
                .filter(VoiceCallRecord.CodingKeys.speakerId == speakerId.uuidString)
                .order(VoiceCallRecord.CodingKeys.updatedAt.desc)
                .fetchOne(db)
            return record.map { VoiceCall(record: $0) }
        }
    }

    @discardableResult
    func createCall(speakerId: UUID) throws -> VoiceCall {
        let now = Date().iso8601String
        var record = VoiceCallRecord(
            id: UUID().uuidString,
            speakerId: speakerId.uuidString,
            title: "",
            turnCount: 0,
            durationSeconds: 0,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }
        // Ensure per-call directory exists
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
