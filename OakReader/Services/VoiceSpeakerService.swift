import Foundation
import GRDB

struct VoiceCharacterService {
    let database: CatalogDatabase

    // MARK: - Voice Calls Directory

    static var voiceCallsDirectory: URL {
        VoiceCallTranscriptStore.baseDirectory
    }

    static func transcriptURL(callId: String) -> URL {
        VoiceCallTranscriptStore.transcriptURL(callId: callId)
    }

    // MARK: - Characters

    func fetchAllCharacters() throws -> [Character] {
        try database.dbQueue.read { db in
            let records = try CharacterRecord
                .order(CharacterRecord.CodingKeys.sortOrder.asc)
                .fetchAll(db)
            return records.map { Character(record: $0) }
        }
    }

    @discardableResult
    func createCharacter(name: String, colorHex: String, language: String) throws -> Character {
        let now = Date().iso8601String
        let maxOrder = try database.dbQueue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) FROM characters") ?? -1
        }
        var record = CharacterRecord(
            id: UUID().uuidString,
            userId: localUserId,
            name: name,
            avatarColorHex: colorHex,
            ttsVoice: "",
            referenceAudioPath: "",
            referenceText: "",
            language: language,
            llmModel: "",
            systemPrompt: "",
            sortOrder: maxOrder + 1,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }
        return Character(record: record)
    }

    func updateCharacter(_ character: Character) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE characters SET name = ?, avatar_color_hex = ?, tts_voice = ?,
                    reference_audio_path = ?, reference_text = ?, language = ?,
                    llm_model = ?, system_prompt = ?, sort_order = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    character.name, character.avatarColorHex, character.ttsVoice,
                    character.referenceAudioPath, character.referenceText, character.language,
                    character.llmModel, character.systemPrompt, character.sortOrder, now,
                    character.id.uuidString
                ]
            )
        }
    }

    func deleteCharacter(id: UUID) throws {
        let calls = try fetchCalls(forCharacterId: id)
        let store = VoiceCallTranscriptStore()
        for call in calls {
            store.deleteCall(callId: call.id.uuidString)
        }
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM characters WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Calls

    func fetchCalls(forCharacterId characterId: UUID) throws -> [VoiceCall] {
        try database.dbQueue.read { db in
            let records = try VoiceCallRecord
                .filter(VoiceCallRecord.CodingKeys.characterId == characterId.uuidString)
                .order(VoiceCallRecord.CodingKeys.updatedAt.desc)
                .fetchAll(db)
            return records.map { VoiceCall(record: $0) }
        }
    }

    func fetchLastCall(forCharacterId characterId: UUID) throws -> VoiceCall? {
        try database.dbQueue.read { db in
            let record = try VoiceCallRecord
                .filter(VoiceCallRecord.CodingKeys.characterId == characterId.uuidString)
                .order(VoiceCallRecord.CodingKeys.updatedAt.desc)
                .fetchOne(db)
            return record.map { VoiceCall(record: $0) }
        }
    }

    @discardableResult
    func createCall(characterId: UUID) throws -> VoiceCall {
        let now = Date().iso8601String
        var record = VoiceCallRecord(
            id: UUID().uuidString,
            characterId: characterId.uuidString,
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
