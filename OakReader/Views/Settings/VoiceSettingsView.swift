import OakReaderAI
import SwiftUI
import UniformTypeIdentifiers
import VoiceAgentKit

struct VoiceSettingsView: View {
    @State private var sttModel: String
    @State private var ttsModel: String
    @State private var vadModel: String
    @State private var turnDetectorEnabled: Bool
    @State private var ttsVoice: String
    @State private var referenceAudioPath: String
    @State private var referenceText: String
    @State private var referenceAudioImportError: String?
    @State private var showAudioFilePicker = false
    @State private var voiceLLMModel: String

    @State private var modelStates: [String: ModelManager.ModelState] = [:]
    @State private var stateTask: Task<Void, Never>?

    private var modelManager: ModelManager { ModelManager.shared }

    init() {
        let prefs = Preferences.shared
        let defaultSTT = KnownModels.stt.first?.repo ?? ""
        let defaultTTS = KnownModels.tts.first?.repo ?? ""
        let defaultVAD = KnownModels.vad.first?.repo ?? ""
        _sttModel = State(initialValue: prefs.voiceSTTModel.isEmpty ? defaultSTT : prefs.voiceSTTModel)
        _ttsModel = State(initialValue: prefs.voiceTTSModel.isEmpty ? defaultTTS : prefs.voiceTTSModel)
        _vadModel = State(initialValue: prefs.voiceVADModel.isEmpty ? defaultVAD : prefs.voiceVADModel)
        _turnDetectorEnabled = State(initialValue: prefs.voiceTurnDetectorEnabled)
        _ttsVoice = State(initialValue: prefs.voiceTTSVoice)
        _referenceAudioPath = State(initialValue: prefs.voiceReferenceAudioPath)
        _referenceText = State(initialValue: prefs.voiceReferenceText)
        _voiceLLMModel = State(initialValue: prefs.voiceLLMModel)
    }

    var body: some View {
        Form {
            llmSection
            sttSection
            ttsSection
            vadSection
            downloadAllSection
        }
        .formStyle(.grouped)
        .onAppear { startObserving() }
        .onDisappear {
            stateTask?.cancel()
            save()
        }
        .onChange(of: requiredRepos) { _, _ in
            refreshRequiredModelStates()
        }
    }

    // MARK: - Sections

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

            Divider()

            Toggle("SmartTurn Endpoint Detection", isOn: $turnDetectorEnabled)

            if turnDetectorEnabled, let turnRepo = KnownModels.turnDetector.first?.repo {
                Text("Uses SmartTurn to distinguish intentional pauses from end-of-turn, reducing false triggers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                modelStatusRow(repo: turnRepo)
            }
        }
    }

    private var downloadAllSection: some View {
        Section("Download All") {
            Button("Download All Models") {
                Task {
                    let config = VoiceModelConfig(
                        sttModel: sttModel,
                        ttsModel: ttsModel,
                        vadModel: vadModel,
                        turnDetectorModel: turnDetectorEnabled ? KnownModels.turnDetector.first?.repo : nil
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
        if turnDetectorEnabled, let td = KnownModels.turnDetector.first?.repo {
            repos.append(td)
        }
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

    private func save() {
        let prefs = Preferences.shared
        prefs.voiceLLMModel = voiceLLMModel
        prefs.voiceSTTModel = sttModel
        prefs.voiceTTSModel = ttsModel
        prefs.voiceVADModel = vadModel
        prefs.voiceTurnDetectorEnabled = turnDetectorEnabled
        prefs.voiceTTSVoice = ttsVoice
        prefs.voiceReferenceAudioPath = referenceAudioPath
        prefs.voiceReferenceText = referenceText
    }
}
