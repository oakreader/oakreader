import AVFoundation
import OakVoice
import SwiftUI

/// Push-to-talk button that captures microphone audio and transcribes to text.
struct VoiceInputButton: View {
    @Binding var transcribedText: String

    @State private var isRecording = false
    @State private var capture: MicrophoneCapture?
    @State private var recordingTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        Button(action: {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        }) {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 16))
                .foregroundStyle(isRecording ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Stop recording" : "Voice input (hold or click)")
        .popover(isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .padding(8)
            }
        }
    }

    private func startRecording() {
        let deviceUID = Preferences.shared.voiceInputDeviceUID
        let mic = MicrophoneCapture(deviceUID: deviceUID.isEmpty ? nil : deviceUID)
        self.capture = mic
        isRecording = true
        error = nil

        recordingTask = Task {
            do {
                let audioStream = try mic.startCapture(sampleRate: 16000)
                let sttModel = Preferences.shared.voiceSTTModel
                let provider = MLXSTTProvider(repoId: sttModel.isEmpty ? KnownModels.stt[0].repo : sttModel)

                let resultStream = provider.transcribeStream(audioStream: audioStream)
                for try await result in resultStream {
                    if result.isFinal {
                        await MainActor.run {
                            if transcribedText.isEmpty {
                                transcribedText = result.text
                            } else {
                                transcribedText += " " + result.text
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = "Voice input failed: \(error.localizedDescription)"
                }
            }
            await MainActor.run {
                isRecording = false
            }
        }
    }

    private func stopRecording() {
        capture?.stopCapture()
        capture = nil
        recordingTask?.cancel()
        recordingTask = nil
        isRecording = false
    }
}
