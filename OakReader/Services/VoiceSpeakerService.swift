import Foundation
import GRDB

struct VoiceCharacterService {
    let database: CatalogDatabase

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: - Voice Calls Directory

    static var voiceCallsDirectory: URL {
        VoiceCallTranscriptStore.baseDirectory
    }

    static func transcriptURL(callId: String) -> URL {
        VoiceCallTranscriptStore.transcriptURL(callId: callId)
    }

    // MARK: - Config File I/O

    private func loadConfig(characterId: UUID) -> CharacterConfig {
        let url = CatalogDatabase.characterConfigURL(characterId: characterId)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(CharacterConfig.self, from: data) else {
            return .default
        }
        return config
    }

    private func saveConfig(_ config: CharacterConfig, characterId: UUID) throws {
        let url = CatalogDatabase.characterConfigURL(characterId: characterId)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    private func deleteConfig(characterId: UUID) {
        let configURL = CatalogDatabase.characterConfigURL(characterId: characterId)
        try? FileManager.default.removeItem(at: configURL)
        let assetsDir = CatalogDatabase.characterAssetsDirectory(characterId: characterId)
        try? FileManager.default.removeItem(at: assetsDir)
    }

    // MARK: - Characters

    func fetchAllCharacters() throws -> [Character] {
        let records = try database.dbQueue.read { db in
            try CharacterRecord
                .order(CharacterRecord.CodingKeys.sortOrder.asc)
                .fetchAll(db)
        }
        return records.map { record in
            let uuid = UUID(uuidString: record.id) ?? UUID()
            let config = loadConfig(characterId: uuid)
            return Character(record: record, config: config)
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
            sortOrder: maxOrder + 1,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }
        let uuid = UUID(uuidString: record.id) ?? UUID()
        var config = CharacterConfig.default
        config.avatar = CharacterAvatar(colorHex: colorHex)
        config.language = language
        try saveConfig(config, characterId: uuid)
        return Character(record: record, config: config)
    }

    func updateCharacter(_ character: Character) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE characters SET name = ?, sort_order = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [character.name, character.sortOrder, now, character.id.uuidString]
            )
        }
        try saveConfig(character.config, characterId: character.id)
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
        deleteConfig(characterId: id)
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
