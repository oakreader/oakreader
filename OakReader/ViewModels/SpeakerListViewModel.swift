import Foundation
import os

private let characterLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.oakreader.OakReader", category: "characters")

enum VoicePanelScreen: Equatable {
    case characterList
    case inCall(Character)
    case callHistory(Character)
}

@Observable
class CharacterListViewModel {
    var characters: [Character] = []
    var screen: VoicePanelScreen = .characterList
    var callHistory: [VoiceCall] = []

    /// The active call record, created when entering a call and finalized on exit.
    var activeCall: VoiceCall?
    /// Timestamp when the current call started, for duration tracking.
    var callStartTime: Date?

    private let service: VoiceCharacterService

    init(service: VoiceCharacterService) {
        self.service = service
        loadCharacters()
    }

    // MARK: - Load

    func loadCharacters() {
        do {
            var loaded = try service.fetchAllCharacters()
            for i in loaded.indices {
                loaded[i].lastCall = try service.fetchLastCall(forCharacterId: loaded[i].id)
            }
            characters = loaded
        } catch {
            characterLog.error("Failed to load characters: \(error.localizedDescription)")
        }
    }

    // MARK: - Navigation

    func startCall(character: Character) {
        do {
            let call = try service.createCall(characterId: character.id)
            activeCall = call
            callStartTime = Date()
            screen = .inCall(character)
        } catch {
            characterLog.error("Failed to create call: \(error.localizedDescription)")
        }
    }

    func showCallHistory(character: Character) {
        do {
            callHistory = try service.fetchCalls(forCharacterId: character.id)
            screen = .callHistory(character)
        } catch {
            characterLog.error("Failed to load call history: \(error.localizedDescription)")
        }
    }

    func backToList() {
        screen = .characterList
        activeCall = nil
        callStartTime = nil
        loadCharacters()
    }

    // MARK: - Call Lifecycle

    func finalizeCall(turnCount: Int) {
        guard let call = activeCall else { return }
        let duration = callStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let title = turnCount > 0 ? "Call with \(turnCount) turns" : ""
        do {
            try service.updateCall(
                id: call.id,
                title: title,
                turnCount: turnCount,
                durationSeconds: duration
            )
        } catch {
            characterLog.error("Failed to finalize call: \(error.localizedDescription)")
        }
        activeCall = nil
        callStartTime = nil
    }

    // MARK: - Character CRUD

    @discardableResult
    func addCharacter(name: String, language: String) -> Character? {
        let colors = ["#5FB236", "#2EA8E5", "#FF8C19", "#A28AE5", "#FF6666", "#E5A02E", "#36B5A0"]
        let color = colors[characters.count % colors.count]
        do {
            let character = try service.createCharacter(name: name, colorHex: color, language: language)
            loadCharacters()
            return character
        } catch {
            characterLog.error("Failed to add character: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteCharacter(_ character: Character) {
        do {
            try service.deleteCharacter(id: character.id)
            loadCharacters()
        } catch {
            characterLog.error("Failed to delete character: \(error.localizedDescription)")
        }
    }

    func updateCharacter(_ character: Character) {
        do {
            try service.updateCharacter(character)
            loadCharacters()
        } catch {
            characterLog.error("Failed to update character: \(error.localizedDescription)")
        }
    }

    // MARK: - Call History CRUD

    func deleteCallFromHistory(_ call: VoiceCall) {
        do {
            try service.deleteCall(id: call.id)
            callHistory.removeAll { $0.id == call.id }
        } catch {
            characterLog.error("Failed to delete call: \(error.localizedDescription)")
        }
    }
}
