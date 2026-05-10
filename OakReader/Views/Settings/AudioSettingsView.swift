import AVFoundation
import SwiftUI
import VoiceAgentKit

struct AudioSettingsView: View {
    @State private var inputDeviceUID: String
    @State private var outputDeviceUID: String
    @State private var isMicTesting = false
    @State private var micTestLevel: Float = 0
    @State private var isSpeakerTesting = false
    @State private var micTestTask: Task<Void, Never>?
    @State private var micTestCapture: MicrophoneCapture?
    @State private var speakerTestTask: Task<Void, Never>?

    private var deviceManager: AudioDeviceManager { AudioDeviceManager.shared }

    init() {
        let prefs = Preferences.shared
        _inputDeviceUID = State(initialValue: prefs.voiceInputDeviceUID)
        _outputDeviceUID = State(initialValue: prefs.voiceOutputDeviceUID)
    }

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(deviceManager.inputDevices) { device in
                        Text(device.name).tag(device.uniqueID)
                    }
                }
                .onChange(of: deviceManager.inputDevices) { _, devices in
                    if !inputDeviceUID.isEmpty,
                       !devices.contains(where: { $0.uniqueID == inputDeviceUID }) {
                        inputDeviceUID = ""
                    }
                }

                HStack {
                    Button(isMicTesting ? "Stop Test" : "Test Microphone") {
                        if isMicTesting {
                            stopMicTest()
                        } else {
                            startMicTest()
                        }
                    }
                    .controlSize(.small)

                    if isMicTesting {
                        AudioLevelMeter(level: micTestLevel)
                            .frame(maxWidth: 160, maxHeight: 8)
                    }
                }
            }

            Section("Speaker") {
                Picker("Speaker", selection: $outputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(deviceManager.outputDevices) { device in
                        Text(device.name).tag(device.uniqueID)
                    }
                }
                .onChange(of: deviceManager.outputDevices) { _, devices in
                    if !outputDeviceUID.isEmpty,
                       !devices.contains(where: { $0.uniqueID == outputDeviceUID }) {
                        outputDeviceUID = ""
                    }
                }

                HStack {
                    Button(isSpeakerTesting ? "Playing..." : "Test Speaker") {
                        if !isSpeakerTesting {
                            startSpeakerTest()
                        }
                    }
                    .controlSize(.small)
                    .disabled(isSpeakerTesting)
                }
            }

            Section {
                Text("Select the audio devices for voice conversations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            stopMicTest()
            stopSpeakerTest()
            save()
        }
    }

    // MARK: - Mic Test

    private func startMicTest() {
        stopMicTest()
        isMicTesting = true
        micTestLevel = 0

        let uid = inputDeviceUID.isEmpty ? nil : inputDeviceUID
        let capture = MicrophoneCapture(deviceUID: uid)
        micTestCapture = capture

        micTestTask = Task {
            do {
                let stream = try capture.startCapture(sampleRate: 16000)
                for await buffer in stream {
                    if Task.isCancelled { break }
                    let rms = AudioDeviceManager.rms(of: buffer)
                    await MainActor.run {
                        micTestLevel += 0.3 * (rms - micTestLevel)
                    }
                }
            } catch {
                // Capture failed
            }
            await MainActor.run {
                isMicTesting = false
                micTestLevel = 0
            }
        }
    }

    private func stopMicTest() {
        micTestTask?.cancel()
        micTestTask = nil
        micTestCapture?.stopCapture()
        micTestCapture = nil
        isMicTesting = false
        micTestLevel = 0
    }

    // MARK: - Speaker Test

    private func startSpeakerTest() {
        stopSpeakerTest()
        isSpeakerTesting = true

        let uid = outputDeviceUID.isEmpty ? nil : outputDeviceUID

        speakerTestTask = Task {
            do {
                let speaker = SpeakerOutput(deviceUID: uid)
                guard let toneBuffer = AudioDeviceManager.generateTestTone() else {
                    await MainActor.run { isSpeakerTesting = false }
                    return
                }

                let stream = AsyncThrowingStream<AVAudioPCMBuffer, Error> { continuation in
                    continuation.yield(toneBuffer)
                    continuation.finish()
                }
                try await speaker.play(buffers: stream)
            } catch {
                // Playback failed
            }
            await MainActor.run { isSpeakerTesting = false }
        }
    }

    private func stopSpeakerTest() {
        speakerTestTask?.cancel()
        speakerTestTask = nil
        isSpeakerTesting = false
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.voiceInputDeviceUID = inputDeviceUID
        prefs.voiceOutputDeviceUID = outputDeviceUID
    }
}

// MARK: - Audio Level Meter

struct AudioLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(min(max(level / 0.15, 0), 1))
            let width = geo.size.width * fraction
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(meterColor(fraction: fraction))
                    .frame(width: width)
                    .animation(.linear(duration: 0.08), value: fraction)
            }
        }
    }

    private func meterColor(fraction: CGFloat) -> Color {
        if fraction < 0.6 {
            return .green
        } else if fraction < 0.85 {
            return .yellow
        } else {
            return .red
        }
    }
}
