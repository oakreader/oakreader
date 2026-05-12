import AVFoundation
import CoreAudio
import SwiftUI
import OakVoiceAI

struct AudioSettingsView: View {
    @State private var inputDeviceUID: String
    @State private var outputDeviceUID: String

    // Mic test states
    private enum MicTestPhase {
        case idle
        case recording
        case playingBack
    }

    @State private var micTestPhase: MicTestPhase = .idle
    @State private var micTestLevel: Float = 0
    @State private var micRecordingCountdown: Int = 0
    @State private var micTestTask: Task<Void, Never>?
    @State private var micTestCapture: MicrophoneCapture?

    // Speaker test states
    @State private var isSpeakerTesting = false
    @State private var speakerTestLevel: Float = 0
    @State private var speakerTestTask: Task<Void, Never>?

    // Volume (bound to CoreAudio)
    @State private var outputVolume: Double = 0.75
    @State private var inputVolume: Double = 0.75

    /// Duration in seconds for mic recording
    private let micRecordDuration = 5

    private var deviceManager: AudioDeviceManager { AudioDeviceManager.shared }

    init() {
        let prefs = Preferences.shared
        _inputDeviceUID = State(initialValue: prefs.voiceInputDeviceUID)
        _outputDeviceUID = State(initialValue: prefs.voiceOutputDeviceUID)
    }

    var body: some View {
        Form {
            // MARK: - Speaker Section
            Section("Speaker") {
                Picker("Speaker", selection: $outputDeviceUID) {
                    Text(defaultOutputLabel).tag("")
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

                HStack(spacing: 12) {
                    Button {
                        if isSpeakerTesting {
                            stopSpeakerTest()
                        } else {
                            startSpeakerTest()
                        }
                    } label: {
                        Label(
                            isSpeakerTesting ? "Stop" : "Test Speaker",
                            systemImage: isSpeakerTesting ? "stop.fill" : "play.fill"
                        )
                        .frame(width: 130, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    SegmentedLevelMeter(level: speakerTestLevel)
                        .frame(height: 8)
                }

                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Slider(value: $outputVolume, in: 0...1)
                        .onChange(of: outputVolume) { _, newValue in
                            let uid = outputDeviceUID.isEmpty ? nil : outputDeviceUID
                            AudioDeviceManager.setVolume(
                                Float(newValue), uid: uid, scope: kAudioObjectPropertyScopeOutput
                            )
                        }
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            // MARK: - Microphone Section
            Section("Microphone") {
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text(defaultInputLabel).tag("")
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

                HStack(spacing: 12) {
                    Button {
                        switch micTestPhase {
                        case .idle:
                            startMicTest()
                        case .recording:
                            // Stop recording early — flows into playback
                            micTestCapture?.stopCapture()
                        case .playingBack:
                            stopMicTest()
                        }
                    } label: {
                        Label(
                            micTestButtonLabel,
                            systemImage: micTestPhase == .idle ? "mic.fill" : "stop.fill"
                        )
                        .frame(width: 130, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    SegmentedLevelMeter(level: micTestLevel)
                        .frame(height: 8)
                }

                if micTestPhase == .recording {
                    Text("Speak now... recording stops in \(micRecordingCountdown)s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if micTestPhase == .playingBack {
                    Text("Playing back your recording...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Slider(value: $inputVolume, in: 0...1)
                        .onChange(of: inputVolume) { _, newValue in
                            let uid = inputDeviceUID.isEmpty ? nil : inputDeviceUID
                            AudioDeviceManager.setVolume(
                                Float(newValue), uid: uid, scope: kAudioObjectPropertyScopeInput
                            )
                        }
                    Image(systemName: "mic.fill.badge.plus")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadVolumes() }
        .onChange(of: outputDeviceUID) { _, _ in loadVolumes() }
        .onChange(of: inputDeviceUID) { _, _ in loadVolumes() }
        .onDisappear {
            stopMicTest()
            stopSpeakerTest()
            save()
        }
    }

    // MARK: - Computed Labels

    private var defaultOutputLabel: String {
        let name = deviceManager.defaultOutputDeviceName
        return name.isEmpty ? "Same as System" : "Same as System (\(name))"
    }

    private var defaultInputLabel: String {
        let name = deviceManager.defaultInputDeviceName
        return name.isEmpty ? "Same as System" : "Same as System (\(name))"
    }

    private var micTestButtonLabel: String {
        switch micTestPhase {
        case .idle: "Test Microphone"
        case .recording: "Recording..."
        case .playingBack: "Stop"
        }
    }

    private func loadVolumes() {
        let outUID = outputDeviceUID.isEmpty ? nil : outputDeviceUID
        let inUID = inputDeviceUID.isEmpty ? nil : inputDeviceUID
        outputVolume = Double(AudioDeviceManager.getVolume(uid: outUID, scope: kAudioObjectPropertyScopeOutput))
        inputVolume = Double(AudioDeviceManager.getVolume(uid: inUID, scope: kAudioObjectPropertyScopeInput))
    }

    // MARK: - Mic Test (Record & Playback)

    private func startMicTest() {
        stopMicTest()
        micTestPhase = .recording
        micTestLevel = 0
        micRecordingCountdown = micRecordDuration

        let uid = inputDeviceUID.isEmpty ? nil : inputDeviceUID
        let capture = MicrophoneCapture(deviceUID: uid)
        micTestCapture = capture

        micTestTask = Task {
            var recordedBuffers: [AVAudioPCMBuffer] = []
            var recordingFormat: AVAudioFormat?

            do {
                let stream = try capture.startCapture(sampleRate: 44100)

                // Countdown timer — stops capture when time expires
                let countdownTask = Task {
                    for remaining in stride(from: micRecordDuration, through: 1, by: -1) {
                        if Task.isCancelled { return }
                        await MainActor.run { micRecordingCountdown = remaining }
                        try? await Task.sleep(for: .seconds(1))
                    }
                    capture.stopCapture()
                }

                // Loop ends naturally when capture.stopCapture() is called
                // (either by countdown or by user pressing Stop)
                for await buffer in stream {
                    if Task.isCancelled { break }

                    // Deep-copy buffer so data survives after engine stops
                    if let copy = Self.copyBuffer(buffer) {
                        recordedBuffers.append(copy)
                    }
                    if recordingFormat == nil { recordingFormat = buffer.format }

                    let rms = AudioDeviceManager.rms(of: buffer)
                    await MainActor.run {
                        micTestLevel += 0.3 * (rms - micTestLevel)
                    }
                }

                countdownTask.cancel()
            } catch {
                capture.stopCapture()
                await MainActor.run { micTestPhase = .idle; micTestLevel = 0 }
                return
            }

            // If fully cancelled (view disappeared), bail out
            if Task.isCancelled {
                await MainActor.run { micTestPhase = .idle; micTestLevel = 0 }
                return
            }

            // Phase 2: Merge and play back
            guard let format = recordingFormat, !recordedBuffers.isEmpty else {
                await MainActor.run { micTestPhase = .idle; micTestLevel = 0 }
                return
            }

            let totalFrames = recordedBuffers.reduce(0) { $0 + Int($1.frameLength) }
            guard let mergedBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(totalFrames)
            ) else {
                await MainActor.run { micTestPhase = .idle; micTestLevel = 0 }
                return
            }
            mergedBuffer.frameLength = AVAudioFrameCount(totalFrames)

            if let dest = mergedBuffer.floatChannelData?[0] {
                var writeOffset = 0
                for buf in recordedBuffers {
                    if let src = buf.floatChannelData?[0] {
                        let count = Int(buf.frameLength)
                        dest.advanced(by: writeOffset).update(from: src, count: count)
                        writeOffset += count
                    }
                }
            }

            await MainActor.run {
                micTestPhase = .playingBack
                micTestLevel = 0
            }

            do {
                let outUID = outputDeviceUID.isEmpty ? nil : outputDeviceUID
                let speaker = SpeakerOutput(deviceUID: outUID)
                let playStream = AsyncThrowingStream<AVAudioPCMBuffer, Error> { continuation in
                    continuation.yield(mergedBuffer)
                    continuation.finish()
                }
                try await speaker.play(buffers: playStream)
            } catch {
                // Playback failed
            }

            await MainActor.run {
                micTestPhase = .idle
                micTestLevel = 0
            }
        }
    }

    /// Deep-copy an AVAudioPCMBuffer so data persists after the engine releases it.
    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength

        let channels = Int(source.format.channelCount)
        if let srcData = source.floatChannelData, let dstData = copy.floatChannelData {
            for ch in 0..<channels {
                dstData[ch].update(from: srcData[ch], count: Int(source.frameLength))
            }
        }
        return copy
    }

    private func stopMicTest() {
        micTestTask?.cancel()
        micTestTask = nil
        micTestCapture?.stopCapture()
        micTestCapture = nil
        micTestPhase = .idle
        micTestLevel = 0
    }

    // MARK: - Speaker Test

    private func startSpeakerTest() {
        stopSpeakerTest()
        isSpeakerTesting = true
        speakerTestLevel = 0

        let uid = outputDeviceUID.isEmpty ? nil : outputDeviceUID

        speakerTestTask = Task {
            let animationTask = Task {
                var phase: Double = 0
                while !Task.isCancelled {
                    phase += 0.15
                    let level = Float(0.4 + 0.3 * sin(phase))
                    await MainActor.run { speakerTestLevel = level }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }

            do {
                let speaker = SpeakerOutput(deviceUID: uid)
                guard let melodyBuffer = AudioDeviceManager.generateTestMelody() else {
                    animationTask.cancel()
                    await MainActor.run { isSpeakerTesting = false; speakerTestLevel = 0 }
                    return
                }

                let stream = AsyncThrowingStream<AVAudioPCMBuffer, Error> { continuation in
                    continuation.yield(melodyBuffer)
                    continuation.finish()
                }
                try await speaker.play(buffers: stream)
            } catch {
                // Playback failed
            }

            animationTask.cancel()
            await MainActor.run { isSpeakerTesting = false; speakerTestLevel = 0 }
        }
    }

    private func stopSpeakerTest() {
        speakerTestTask?.cancel()
        speakerTestTask = nil
        isSpeakerTesting = false
        speakerTestLevel = 0
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.voiceInputDeviceUID = inputDeviceUID
        prefs.voiceOutputDeviceUID = outputDeviceUID
    }
}

// MARK: - Segmented Level Meter (Zoom-style)

struct SegmentedLevelMeter: View {
    let level: Float

    private let segmentCount = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { index in
                let threshold = Float(index) / Float(segmentCount)
                let isActive = level > threshold
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(segmentColor(index: index))
                    .opacity(isActive ? 1 : 0.15)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func segmentColor(index: Int) -> Color {
        let fraction = Double(index) / Double(segmentCount)
        if fraction < 0.6 {
            return .green
        } else if fraction < 0.85 {
            return .yellow
        } else {
            return .red
        }
    }
}
