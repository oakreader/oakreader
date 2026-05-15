import Foundation

enum VoicePanelScreen: Equatable {
    case callList
    case inCall
    case callHistory
}

@Observable
class VoiceCallListViewModel {
    var screen: VoicePanelScreen = .callList
    var callHistory: [VoiceCall] = []

    /// The active call record, created when entering a call and finalized on exit.
    var activeCall: VoiceCall?
    /// Timestamp when the current call started, for duration tracking.
    var callStartTime: Date?

    private let service: VoiceCallService

    init(service: VoiceCallService) {
        self.service = service
    }

    // MARK: - Navigation

    func startCall() {
        do {
            let call = try service.createCall()
            activeCall = call
            callStartTime = Date()
            screen = .inCall
        } catch {
            Log.error(Log.voice, "Failed to create call: \(error.localizedDescription)")
        }
    }

    func showCallHistory() {
        do {
            callHistory = try service.fetchAllCalls()
            screen = .callHistory
        } catch {
            Log.error(Log.voice, "Failed to load call history: \(error.localizedDescription)")
        }
    }

    func backToMain() {
        screen = .callList
        activeCall = nil
        callStartTime = nil
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
            Log.error(Log.voice, "Failed to finalize call: \(error.localizedDescription)")
        }
        activeCall = nil
        callStartTime = nil
    }

    // MARK: - Call History CRUD

    func deleteCallFromHistory(_ call: VoiceCall) {
        do {
            try service.deleteCall(id: call.id)
            callHistory.removeAll { $0.id == call.id }
        } catch {
            Log.error(Log.voice, "Failed to delete call: \(error.localizedDescription)")
        }
    }
}
