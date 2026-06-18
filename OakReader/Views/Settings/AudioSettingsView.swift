import AVFoundation
import CoreAudio
import SwiftUI
import OakAgent
import OakVoice

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

    // Output test states
    @State private var isSpeakerTesting = false
    @State private var speakerTestLevel: Float = 0
    @State private var speakerTestTask: Task<Void, Never>?

    // Volume (bound to CoreAudio)
    @State private var outputVolume: Double = 0.75
    @State private var inputVolume: Double = 0.75

    /// Duration in seconds for mic recording
    private let micRecordDuration = 5

    // MARK: - Voice / AI state

    @State private var store = ConfiguredProviderStore.shared

    // Chat default (read-only display for Voice Chat LLM)
    @State private var chatProviderId: String = ""
    @State private var chatModel: String = ""

    // Voice Chat LLM
    @State private var voiceLLMUseChatDefault: Bool = true
    @State private var voiceLLMProviderId: String = ""
    @State private var voiceLLMModel: String = ""

    // Voice providers
    @State private var ttsProvider: String = ""
    @State private var sttProvider: String = ""
    @State private var elevenLabsVoiceId: String = ""
    @State private var elevenLabsTTSModelId: String = ""
    @State private var openAITTSVoice: String = ""
    @State private var geminiTTSVoice: String = ""
    @State private var fishAudioReferenceId: String = ""

    // Inline API keys
    @State private var elevenLabsAPIKey: String = ""
    @State private var fishAudioAPIKey: String = ""
    @State private var openAIAPIKey: String = ""
    @State private var geminiAPIKey: String = ""
    @State private var originalOpenAIAPIKey: String = ""
    @State private var originalGeminiAPIKey: String = ""

    private let openAIVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
    private let geminiVoices = ["Kore", "Puck", "Zephyr", "Charon", "Fenrir", "Aoede", "Leda", "Orus"]

    private var deviceManager: AudioDeviceManager { AudioDeviceManager.shared }

    init() {
        let prefs = Preferences.shared
        _inputDeviceUID = State(initialValue: prefs.voiceInputDeviceUID)
        _outputDeviceUID = State(initialValue: prefs.voiceOutputDeviceUID)

        // Chat default
        let pid = prefs.aiProviderId
        let defaultModel = ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
        _chatProviderId = State(initialValue: pid)
        _chatModel = State(initialValue: prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel)

        // Voice Chat LLM
        let vlm = prefs.voiceLLMModel
        _voiceLLMUseChatDefault = State(initialValue: vlm.isEmpty)
        _voiceLLMModel = State(initialValue: vlm.isEmpty ? defaultModel : vlm)
        let vlmProvider = Self.providerForModel(vlm.isEmpty ? (prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel) : vlm) ?? pid
        _voiceLLMProviderId = State(initialValue: vlmProvider)

        // Voice providers
        _ttsProvider = State(initialValue: prefs.voiceTTSProvider)
        _sttProvider = State(initialValue: prefs.voiceSTTProvider)
        _elevenLabsVoiceId = State(initialValue: prefs.elevenLabsVoiceId)
        _elevenLabsTTSModelId = State(initialValue: prefs.elevenLabsTTSModelId)
        _openAITTSVoice = State(initialValue: prefs.openAITTSVoice)
        _geminiTTSVoice = State(initialValue: prefs.geminiTTSVoice)
        _fishAudioReferenceId = State(initialValue: prefs.fishAudioReferenceId)

        // Inline API keys
        _elevenLabsAPIKey = State(initialValue: prefs.elevenLabsAPIKey)
        _fishAudioAPIKey = State(initialValue: prefs.fishAudioAPIKey)
        let openAIKey = KeychainService.apiKey(forProviderId: "openai") ?? ""
        let geminiKey = KeychainService.apiKey(forProviderId: "google") ?? ""
        _openAIAPIKey = State(initialValue: openAIKey)
        _geminiAPIKey = State(initialValue: geminiKey)
        _originalOpenAIAPIKey = State(initialValue: openAIKey)
        _originalGeminiAPIKey = State(initialValue: geminiKey)
    }

    private static func providerForModel(_ modelId: String) -> String? {
        for provider in ConfiguredProviderStore.shared.configuredLLMProviders {
            if provider.models.contains(where: { $0.id == modelId }) {
                return provider.id
            }
        }
        return nil
    }

    var body: some View {
        Form {
            // MARK: - Output Section
            Section("Output") {
                Picker("Device", selection: $outputDeviceUID) {
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

                LabeledContent("Volume") {
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

                LabeledContent("Test") {
                    HStack(spacing: 12) {
                        SegmentedLevelMeter(level: speakerTestLevel, isActive: isSpeakerTesting)
                            .frame(maxWidth: .infinity)
                            .frame(height: 8)

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
                            .frame(width: 128, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            // MARK: - Input Section
            Section("Input") {
                Picker("Device", selection: $inputDeviceUID) {
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

                LabeledContent("Input Volume") {
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

                LabeledContent("Test") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            SegmentedLevelMeter(level: micTestLevel, isActive: micTestPhase != .idle)
                                .frame(maxWidth: .infinity)
                                .frame(height: 8)

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
                                .frame(width: 128, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }

                        if micTestPhase == .recording {
                            Text("Recording stops in \(micRecordingCountdown)s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if micTestPhase == .playingBack {
                            Text("Playing back your recording")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            voiceChatSection
            transcribeSection
            ttsSection
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

    // MARK: - Voice Chat LLM

    @ViewBuilder
    private var voiceChatSection: some View {
        Section("Voice Chat LLM") {
            Toggle("Use Chat default", isOn: $voiceLLMUseChatDefault)

            if voiceLLMUseChatDefault {
                chatDefaultLabel
            } else {
                llmPickers(providerId: $voiceLLMProviderId, model: $voiceLLMModel)
            }
        }
    }

    // MARK: - Transcribe

    @ViewBuilder
    private var transcribeSection: some View {
        Section("Transcribe") {
            Picker("Provider", selection: $sttProvider) {
                ForEach(VoiceProviderType.allCases, id: \.rawValue) { type in
                    Text(type.displayName).tag(type.rawValue)
                }
            }
            credentialFields(for: VoiceProviderType(rawValue: sttProvider) ?? .elevenLabs)
        }
    }

    // MARK: - Text-to-Speech

    @ViewBuilder
    private var ttsSection: some View {
        Section("Text-to-Speech") {
            Picker("Provider", selection: $ttsProvider) {
                ForEach(VoiceProviderType.allCases, id: \.rawValue) { type in
                    Text(type.displayName).tag(type.rawValue)
                }
            }

            switch VoiceProviderType(rawValue: ttsProvider) ?? .elevenLabs {
            case .elevenLabs:
                credentialFields(for: .elevenLabs)
                if !elevenLabsAPIKey.isEmpty {
                    TextField("Voice ID", text: $elevenLabsVoiceId)
                        .textFieldStyle(.roundedBorder)
                    Picker("TTS Model", selection: $elevenLabsTTSModelId) {
                        Text("Turbo v2.5 (fastest)").tag("eleven_turbo_v2_5")
                        Text("Flash v2.5 (fast)").tag("eleven_flash_v2_5")
                        Text("Multilingual v2 (quality)").tag("eleven_multilingual_v2")
                    }
                }
            case .openAI:
                Picker("Voice", selection: $openAITTSVoice) {
                    ForEach(openAIVoices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                credentialFields(for: .openAI)
            case .gemini:
                Picker("Voice", selection: $geminiTTSVoice) {
                    ForEach(geminiVoices, id: \.self) { Text($0).tag($0) }
                }
                credentialFields(for: .gemini)
            case .fishAudio:
                fishAudioFields
            }
        }
    }

    // MARK: - Credential helpers

    /// Inline API-key entry for the selected voice provider.
    @ViewBuilder
    private func credentialFields(for type: VoiceProviderType) -> some View {
        switch type {
        case .elevenLabs:
            SecureField("ElevenLabs API Key", text: $elevenLabsAPIKey, prompt: Text("API Key"))
                .textFieldStyle(.roundedBorder)
            Text("Get your API key from elevenlabs.io")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .openAI:
            SecureField("OpenAI API Key", text: $openAIAPIKey, prompt: Text("API Key"))
                .textFieldStyle(.roundedBorder)
            Text("Shared with the OpenAI chat provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .gemini:
            SecureField("Google Gemini API Key", text: $geminiAPIKey, prompt: Text("API Key"))
                .textFieldStyle(.roundedBorder)
            Text("Shared with the Google chat provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .fishAudio:
            fishAudioFields
        }
    }

    @ViewBuilder
    private var fishAudioFields: some View {
        SecureField("Fish Audio API Key", text: $fishAudioAPIKey)
            .textFieldStyle(.roundedBorder)
        TextField("Voice Reference ID (optional)", text: $fishAudioReferenceId)
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func llmPickers(providerId: Binding<String>, model: Binding<String>) -> some View {
        if store.configuredLLMProviders.isEmpty {
            Text("Add a provider in AI settings to select a model.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Provider", selection: providerId) {
                ForEach(store.configuredLLMProviders) { p in
                    Text(p.displayName).tag(p.id)
                }
            }
            .onChange(of: providerId.wrappedValue) { _, newValue in
                model.wrappedValue = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
            }

            if let provider = ProviderRegistry.shared.provider(for: providerId.wrappedValue) {
                Picker("Model", selection: model) {
                    ForEach(provider.models) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }
        }
    }

    private var chatDefaultLabel: some View {
        let providerName = ProviderRegistry.shared.provider(for: chatProviderId)?.displayName ?? chatProviderId
        let modelName = ProviderRegistry.shared.provider(for: chatProviderId)?.models.first(where: { $0.id == chatModel })?.name ?? chatModel
        return LabeledContent("Using", value: "\(providerName) / \(modelName)")
            .foregroundStyle(.secondary)
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

    // MARK: - Output Test

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

        // Voice Chat LLM
        prefs.voiceLLMModel = voiceLLMUseChatDefault ? "" : voiceLLMModel

        // Voice providers
        prefs.voiceTTSProvider = ttsProvider
        prefs.voiceSTTProvider = sttProvider
        prefs.elevenLabsVoiceId = elevenLabsVoiceId
        prefs.elevenLabsTTSModelId = elevenLabsTTSModelId
        prefs.openAITTSVoice = openAITTSVoice
        prefs.geminiTTSVoice = geminiTTSVoice
        prefs.fishAudioReferenceId = fishAudioReferenceId.trimmingCharacters(in: .whitespacesAndNewlines)

        // Inline API keys
        prefs.elevenLabsAPIKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.fishAudioAPIKey = fishAudioAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // OpenAI / Gemini keys share the chat provider's Keychain entry. Only write when
        // changed and non-empty so clearing the field never wipes the chat provider's key.
        let trimmedOpenAI = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOpenAI != originalOpenAIAPIKey, !trimmedOpenAI.isEmpty {
            KeychainService.setAPIKey(trimmedOpenAI, forProviderId: "openai")
        }
        let trimmedGemini = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedGemini != originalGeminiAPIKey, !trimmedGemini.isEmpty {
            KeychainService.setAPIKey(trimmedGemini, forProviderId: "google")
        }

        store.refresh()
    }
}

// MARK: - Segmented Level Meter (Zoom-style)

struct SegmentedLevelMeter: View {
    let level: Float
    var isActive = true

    private let segmentCount = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { index in
                let threshold = Float(index) / Float(segmentCount)
                let isLit = level > threshold
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(segmentFill(index: index, isLit: isLit))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func segmentFill(index: Int, isLit: Bool) -> Color {
        guard isActive else { return Color.secondary.opacity(0.14) }
        return segmentColor(index: index).opacity(isLit ? 1 : 0.15)
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
