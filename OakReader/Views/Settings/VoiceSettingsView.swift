import AVFoundation
import OakReaderAI
import SwiftUI
import UniformTypeIdentifiers
import VoiceAgentKit

struct VoiceSettingsView: View {
    @State private var sttModel: String
    @State private var ttsModel: String
    @State private var vadModel: String
    @State private var ttsVoice: String
    @State private var referenceAudioPath: String
    @State private var referenceText: String
    @State private var referenceAudioImportError: String?
    @State private var showAudioFilePicker = false
    @State private var voiceLLMModel: String
    @State private var voiceLanguage: String
    @State private var liveTranscription: Bool

    // Audio device selection
    @State private var inputDeviceUID: String
    @State private var outputDeviceUID: String
    @State private var isMicTesting = false
    @State private var micTestLevel: Float = 0
    @State private var isSpeakerTesting = false
    @State private var micTestTask: Task<Void, Never>?
    @State private var micTestCapture: MicrophoneCapture?
    @State private var speakerTestTask: Task<Void, Never>?

    @State private var modelStates: [String: ModelManager.ModelState] = [:]
    @State private var stateTask: Task<Void, Never>?

    private var deviceManager: AudioDeviceManager { AudioDeviceManager.shared }
    private var modelManager: ModelManager { ModelManager.shared }

    init() {
        let prefs = Preferences.shared
        let defaultSTT = KnownModels.stt.first?.repo ?? ""
        let defaultTTS = KnownModels.tts.first?.repo ?? ""
        let defaultVAD = KnownModels.vad.first?.repo ?? ""
        _sttModel = State(initialValue: prefs.voiceSTTModel.isEmpty ? defaultSTT : prefs.voiceSTTModel)
        _ttsModel = State(initialValue: prefs.voiceTTSModel.isEmpty ? defaultTTS : prefs.voiceTTSModel)
        _vadModel = State(initialValue: prefs.voiceVADModel.isEmpty ? defaultVAD : prefs.voiceVADModel)
        _ttsVoice = State(initialValue: prefs.voiceTTSVoice)
        _referenceAudioPath = State(initialValue: prefs.voiceReferenceAudioPath)
        _referenceText = State(initialValue: prefs.voiceReferenceText)
        _voiceLLMModel = State(initialValue: prefs.voiceLLMModel)
        _voiceLanguage = State(initialValue: prefs.voiceLanguage)
        _liveTranscription = State(initialValue: prefs.voiceLiveTranscription)
        _inputDeviceUID = State(initialValue: prefs.voiceInputDeviceUID)
        _outputDeviceUID = State(initialValue: prefs.voiceOutputDeviceUID)
    }

    var body: some View {
        Form {
            audioDeviceSection
            languageSection
            llmSection
            sttSection
            liveTranscriptionSection
            ttsSection
            vadSection
            downloadAllSection
        }
        .formStyle(.grouped)
        .onAppear { startObserving() }
        .onDisappear {
            stopMicTest()
            stopSpeakerTest()
            stateTask?.cancel()
            save()
        }
        .onChange(of: requiredRepos) { _, _ in
            refreshRequiredModelStates()
        }
    }

    // MARK: - Audio Device Section

    private var audioDeviceSection: some View {
        Section("Audio Devices") {
            // Microphone picker
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

            // Mic test
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

            Divider()

            // Speaker picker
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

            // Speaker test
            HStack {
                Button(isSpeakerTesting ? "Playing..." : "Test Speaker") {
                    if !isSpeakerTesting {
                        startSpeakerTest()
                    }
                }
                .controlSize(.small)
                .disabled(isSpeakerTesting)
            }

            Text("Select the audio devices for voice conversations.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sections

    private var languageSection: some View {
        Section("Language") {
            Picker("Language", selection: $voiceLanguage) {
                ForEach(VoiceLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }

            Text("Select the language for speech recognition and synthesis. The STT model auto-detects language, but TTS uses this setting for correct pronunciation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var llmSection: some View {
        Section("Language Model") {
            let pid = Preferences.shared.aiProviderId
            let models = ProviderRegistry.shared.provider(for: pid)?.models ?? []

            Picker("Model", selection: $voiceLLMModel) {
                Text("Same as AI Chat").tag("")
                ForEach(models.filter { !$0.reasoning }) { model in
                    Text(model.name).tag(model.id)
                }
                let reasoningModels = models.filter { $0.reasoning }
                if !reasoningModels.isEmpty {
                    Section("Reasoning (slower)") {
                        ForEach(reasoningModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            }

            Text("Pick a fast, non-reasoning model for lower latency. Reasoning models (Opus, o3, etc.) think before responding, adding seconds of delay.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sttSection: some View {
        Section("Speech-to-Text") {
            Picker("Model", selection: $sttModel) {
                ForEach(KnownModels.stt) { option in
                    Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                }
            }

            modelStatusRow(repo: sttModel)
        }
    }

    private var liveTranscriptionSection: some View {
        Section("Live Transcription") {
            Toggle("Show words as you speak", isOn: $liveTranscription)

            if liveTranscription {
                Text("Live transcription requires Parakeet model (not available with current TTS library).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ttsSection: some View {
        Section("Text-to-Speech") {
            Picker("Model", selection: $ttsModel) {
                ForEach(KnownModels.tts) { option in
                    Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                }
            }

            TextField("Voice Identifier (optional)", text: $ttsVoice)
                .textFieldStyle(.roundedBorder)

            Text("Leave empty for default voice. Qwen3-TTS voices: Aiden, Ryan, Vivian, Serena. Kokoro voices: af_bella, af_heart, am_adam.")
                .font(.caption)
                .foregroundStyle(.secondary)

            modelStatusRow(repo: ttsModel)

            // Voice cloning reference audio
            Divider()

            Text("Voice Cloning")
                .font(.headline)

            HStack {
                if referenceAudioPath.isEmpty {
                    Text("No reference audio selected")
                        .foregroundStyle(.secondary)
                } else {
                    Text(URL(fileURLWithPath: referenceAudioPath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Choose...") {
                    showAudioFilePicker = true
                }
                .controlSize(.small)
                if !referenceAudioPath.isEmpty {
                    Button("Clear") {
                        referenceAudioPath = ""
                        referenceAudioImportError = nil
                    }
                    .controlSize(.small)
                }
            }
            .fileImporter(
                isPresented: $showAudioFilePicker,
                allowedContentTypes: [.audio, .wav],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    importReferenceAudio(from: url)
                }
            }

            if let referenceAudioImportError {
                Text(referenceAudioImportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !referenceAudioPath.isEmpty {
                TextField("Reference Text (transcript of the audio clip)", text: $referenceText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            Text("Select a .wav file and provide its transcript to clone a speaker's voice. Qwen3-TTS requires both the audio and text for voice cloning.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var vadSection: some View {
        Section("Voice Activity Detection") {
            Picker("VAD Model", selection: $vadModel) {
                ForEach(KnownModels.vad) { option in
                    Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                }
            }

            modelStatusRow(repo: vadModel)
        }
    }

    private var downloadAllSection: some View {
        Section("Download All") {
            Button("Download All Models") {
                Task {
                    let config = VoiceModelConfig(
                        sttModel: sttModel,
                        ttsModel: ttsModel,
                        vadModel: vadModel
                    )
                    try? await modelManager.downloadAll(config)
                }
            }
            .disabled(allDownloaded)

            if allDownloaded {
                Label("All models downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    // MARK: - Model Status Row

    @ViewBuilder
    private func modelStatusRow(repo: String) -> some View {
        let state = modelStates[repo] ?? .notDownloaded
        HStack {
            switch state {
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("Not downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download") {
                    Task { try? await modelManager.download(repo) }
                }
                .controlSize(.small)

            case .downloading(let progress):
                if progress > 0 && progress < 1 {
                    ProgressView(value: progress)
                        .frame(maxWidth: 120)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress >= 1 ? "Finishing..." : "Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .downloaded, .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete") {
                    Task { await modelManager.delete(repo) }
                }
                .controlSize(.small)

            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    Task { try? await modelManager.download(repo) }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private var requiredRepos: [String] {
        var repos = [sttModel, ttsModel, vadModel]
        // Parakeet live STT not available with current TTS library
        return repos
    }

    private var allDownloaded: Bool {
        for repo in requiredRepos {
            switch modelStates[repo] {
            case .downloaded, .ready:
                continue
            default:
                return false
            }
        }
        return true
    }

    private func startObserving() {
        stateTask?.cancel()
        refreshRequiredModelStates()

        // Observe ongoing changes
        stateTask = Task {
            for await (repo, state) in modelManager.stateChanges {
                await MainActor.run { modelStates[repo] = state }
            }
        }
    }

    private func refreshRequiredModelStates() {
        let repos = requiredRepos
        Task {
            for repo in repos {
                let state = await modelManager.state(for: repo)
                await MainActor.run { modelStates[repo] = state }
            }
        }
    }

    private func importReferenceAudio(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let destination = try Self.copyReferenceAudioIntoAppStorage(from: url)
            referenceAudioPath = destination.path
            referenceAudioImportError = nil
        } catch {
            referenceAudioImportError = "Could not import reference audio: \(error.localizedDescription)"
        }
    }

    private static func copyReferenceAudioIntoAppStorage(from sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = CatalogDatabase.dataDirectory
            .appendingPathComponent("voice-reference-audio", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = sourceURL.lastPathComponent.isEmpty ? "reference-audio.wav" : sourceURL.lastPathComponent
        let destination = directory
            .appendingPathComponent("\(UUID().uuidString)-\(fileName)")

        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
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
                        // Simple smoothing
                        micTestLevel += 0.3 * (rms - micTestLevel)
                    }
                }
            } catch {
                // Capture failed — stop silently
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
                // Playback failed — stop silently
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
        prefs.voiceLLMModel = voiceLLMModel
        prefs.voiceSTTModel = sttModel
        prefs.voiceTTSModel = ttsModel
        prefs.voiceVADModel = vadModel
        prefs.voiceTTSVoice = ttsVoice
        prefs.voiceReferenceAudioPath = referenceAudioPath
        prefs.voiceReferenceText = referenceText
        prefs.voiceLanguage = voiceLanguage
        prefs.voiceLiveTranscription = liveTranscription
        prefs.voiceInputDeviceUID = inputDeviceUID
        prefs.voiceOutputDeviceUID = outputDeviceUID
    }
}

// MARK: - Audio Level Meter

private struct AudioLevelMeter: View {
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

// MARK: - Voice Language

enum VoiceLanguage: String, CaseIterable, Identifiable {
    case en
    case zh
    case ja
    case ko
    case fr
    case de
    case es
    case ru
    case ar
    case pt

    var id: String { rawValue }

    var code: String { rawValue }

    var displayName: String {
        switch self {
        case .en: "English"
        case .zh: "Chinese (中文)"
        case .ja: "Japanese (日本語)"
        case .ko: "Korean (한국어)"
        case .fr: "French (Français)"
        case .de: "German (Deutsch)"
        case .es: "Spanish (Español)"
        case .ru: "Russian (Русский)"
        case .ar: "Arabic (العربية)"
        case .pt: "Portuguese (Português)"
        }
    }
}
