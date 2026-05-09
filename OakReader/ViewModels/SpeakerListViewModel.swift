import Foundation
import os

private let speakerLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.oakreader.OakReader", category: "speakers")

enum VoicePanelScreen: Equatable {
    case speakerList
    case inCall(Speaker)
    case callHistory(Speaker)
}

@Observable
class SpeakerListViewModel {
    var speakers: [Speaker] = []
    var screen: VoicePanelScreen = .speakerList
    var callHistory: [VoiceCall] = []

    /// The active call record, created when entering a call and finalized on exit.
    var activeCall: VoiceCall?
    /// Timestamp when the current call started, for duration tracking.
    var callStartTime: Date?

    private let service: VoiceSpeakerService

    init(service: VoiceSpeakerService) {
        self.service = service
        loadSpeakers()
    }

    // MARK: - Load

    func loadSpeakers() {
        do {
            var loaded = try service.fetchAllSpeakers()
            for i in loaded.indices {
                loaded[i].lastCall = try service.fetchLastCall(forSpeakerId: loaded[i].id)
            }
            speakers = loaded
        } catch {
            speakerLog.error("Failed to load speakers: \(error.localizedDescription)")
        }
    }

    // MARK: - Navigation

    func startCall(speaker: Speaker) {
        do {
            let call = try service.createCall(speakerId: speaker.id)
            activeCall = call
            callStartTime = Date()
            screen = .inCall(speaker)
        } catch {
            speakerLog.error("Failed to create call: \(error.localizedDescription)")
        }
    }

    func showCallHistory(speaker: Speaker) {
        do {
            callHistory = try service.fetchCalls(forSpeakerId: speaker.id)
            screen = .callHistory(speaker)
        } catch {
            speakerLog.error("Failed to load call history: \(error.localizedDescription)")
        }
    }

    func backToList() {
        screen = .speakerList
        activeCall = nil
        callStartTime = nil
        loadSpeakers()
    }

    // MARK: - Call Lifecycle

    func finalizeCall(turnCount: Int) {
        guard let call = activeCall else { return }
        let duration = callStartTime.map { Date().timeIntervalSince($0) } ?? 0
        // Generate title from turn count
        let title = turnCount > 0 ? "Call with \(turnCount) turns" : ""
        do {
            try service.updateCall(
                id: call.id,
                title: title,
                turnCount: turnCount,
                durationSeconds: duration
            )
        } catch {
            speakerLog.error("Failed to finalize call: \(error.localizedDescription)")
        }
        activeCall = nil
        callStartTime = nil
    }

    // MARK: - Speaker CRUD

    @discardableResult
    func addSpeaker(name: String, language: String) -> Speaker? {
        let colors = ["#5FB236", "#2EA8E5", "#FF8C19", "#A28AE5", "#FF6666", "#E5A02E", "#36B5A0"]
        let color = colors[speakers.count % colors.count]
        do {
            let speaker = try service.createSpeaker(name: name, colorHex: color, language: language)
            loadSpeakers()
            return speaker
        } catch {
            speakerLog.error("Failed to add speaker: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteSpeaker(_ speaker: Speaker) {
        do {
            try service.deleteSpeaker(id: speaker.id)
            loadSpeakers()
        } catch {
            speakerLog.error("Failed to delete speaker: \(error.localizedDescription)")
        }
    }

    func updateSpeaker(_ speaker: Speaker) {
        do {
            try service.updateSpeaker(speaker)
            loadSpeakers()
        } catch {
            speakerLog.error("Failed to update speaker: \(error.localizedDescription)")
        }
    }

    // MARK: - Call History CRUD

    func deleteCallFromHistory(_ call: VoiceCall) {
        do {
            try service.deleteCall(id: call.id)
            callHistory.removeAll { $0.id == call.id }
        } catch {
            speakerLog.error("Failed to delete call: \(error.localizedDescription)")
        }
    }
}
