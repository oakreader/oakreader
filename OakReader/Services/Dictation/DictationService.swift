import AVFoundation
import os
import VoiceAgentKit

private let log = Logger(subsystem: "OakReader", category: "DictationService")

/// Orchestrates real-time dictation: mic capture → STT provider → dictation events.
///
/// The service is `@Observable` so SwiftUI views can react to `isDictating`
/// and `partialText`. Call `toggle()` to start or stop dictation.
@Observable
@MainActor
final class DictationService {
    /// Whether dictation is currently active.
    private(set) var isDictating = false

    /// The current partial (interim) transcription text.
    private(set) var partialText = ""

    /// Non-nil when the service wants to show an error alert to the user.
    var errorMessage: String?

    /// Callback invoked on the main actor for each dictation event.
    /// Wire this to the text view's insertion methods.
    var onDictationEvent: ((DictationEvent) -> Void)?

    private var micCapture: MicrophoneCapture?
    private var dictationTask: Task<Void, Never>?

    /// Toggle dictation on/off.
    func toggle() {
        print("[Dictation] toggle() isDictating=\(isDictating)")
        if isDictating {
            stop()
        } else {
            start()
        }
    }

    /// Start dictation: create mic capture, provider, and begin streaming.
    func start() {
        guard !isDictating else {
            print("[Dictation] start() skipped — already dictating")
            return
        }

        let prefs = Preferences.shared
        print("[Dictation] STT provider='\(prefs.voiceSTTProvider)', apiKey empty=\(prefs.elevenLabsAPIKey.isEmpty)")
        let provider = makeProvider(prefs: prefs)

        guard let provider else {
            print("[Dictation] ⚠ No provider — showing error alert")
            log.error("No dictation provider available — check STT provider settings and API key")
            errorMessage = "Dictation requires an ElevenLabs API key. Configure it in Settings → Voice → ElevenLabs."
            return
        }

        print("[Dictation] ✓ Provider created, starting mic capture...")
        isDictating = true
        partialText = ""

        let inputUID = prefs.voiceInputDeviceUID.isEmpty ? nil : prefs.voiceInputDeviceUID
        let mic = MicrophoneCapture(deviceUID: inputUID)
        self.micCapture = mic

        dictationTask = Task { [weak self] in
            guard let self else { return }

            do {
                let audioStream = try mic.startCapture(sampleRate: 16000)
                print("[Dictation] ✓ Mic capture started, connecting to STT...")
                let eventStream = provider.startDictation(audioStream: audioStream)

                for await event in eventStream {
                    if Task.isCancelled { break }
                    print("[Dictation] Event: \(event)")
                    self.handleEvent(event)
                }
                print("[Dictation] Event stream ended")
            } catch {
                if !Task.isCancelled {
                    print("[Dictation] ✗ Capture error: \(error)")
                    log.error("Dictation capture error: \(error.localizedDescription)")
                    self.handleEvent(.error(error.localizedDescription))
                }
            }

            // Clean up when the stream ends
            self.cleanUp()
        }
    }

    /// Stop dictation and clean up resources.
    func stop() {
        guard isDictating else { return }
        dictationTask?.cancel()
        dictationTask = nil
        micCapture?.stopCapture()
        micCapture = nil
        isDictating = false
        partialText = ""
    }

    // MARK: - Private

    private func handleEvent(_ event: DictationEvent) {
        switch event {
        case .partial(let text):
            partialText = text
        case .final(let text):
            partialText = ""
        case .error:
            partialText = ""
        }
        onDictationEvent?(event)
    }

    private func cleanUp() {
        micCapture?.stopCapture()
        micCapture = nil
        isDictating = false
        partialText = ""
    }

    private func makeProvider(prefs: Preferences) -> (any DictationProvider)? {
        // Currently only ElevenLabs is supported for dictation.
        // The voice STT provider preference determines which engine to use.
        let providerType = prefs.voiceSTTProvider

        switch providerType {
        case "elevenlabs":
            let apiKey = prefs.elevenLabsAPIKey
            guard !apiKey.isEmpty else {
                log.warning("ElevenLabs API key is empty")
                return nil
            }
            return ElevenLabsDictationProvider(
                apiKey: apiKey,
                modelId: prefs.elevenLabsSTTModelId,
                languageCode: prefs.voiceLanguage
            )
        default:
            // On-device STT could be added here in the future.
            // For now, fall back to ElevenLabs if an API key is available.
            let apiKey = prefs.elevenLabsAPIKey
            if !apiKey.isEmpty {
                return ElevenLabsDictationProvider(
                    apiKey: apiKey,
                    modelId: prefs.elevenLabsSTTModelId,
                    languageCode: prefs.voiceLanguage
                )
            }
            return nil
        }
    }
}
