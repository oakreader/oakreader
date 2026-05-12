import SwiftUI
import OakVoiceAI

struct LocalModelsSettingsView: View {
    @State private var sttModel: String
    @State private var ttsModel: String
    @State private var vadModel: String
    @State private var hfEndpoint: String

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
        _hfEndpoint = State(initialValue: prefs.hfEndpoint)
    }

    private var allRepos: [String] { [sttModel, ttsModel, vadModel] }

    private var allDownloaded: Bool {
        allRepos.allSatisfy { repo in
            switch modelStates[repo] {
            case .downloaded, .ready: return true
            default: return false
            }
        }
    }

    var body: some View {
        Form {
            sttSection
            ttsSection
            vadSection
            downloadAllSection
        }
        .formStyle(.grouped)
        .onAppear {
            startObserving()
            applyHFEndpoint(hfEndpoint)
        }
        .onDisappear {
            stateTask?.cancel()
            save()
        }
        .onChange(of: allRepos) { _, _ in
            refreshModelStates()
        }
    }

    // MARK: - Sections

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
            modelStatusRow(repo: ttsModel)
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
            TextField("HuggingFace Endpoint (optional)", text: $hfEndpoint)
                .textFieldStyle(.roundedBorder)
                .onChange(of: hfEndpoint) { _, newValue in
                    applyHFEndpoint(newValue)
                }

            Text("Leave empty for default (huggingface.co). Use https://hf-mirror.com if downloads fail due to network restrictions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Download All Models") {
                Task {
                    applyHFEndpoint(hfEndpoint)
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
                    Task {
                        applyHFEndpoint(hfEndpoint)
                        try? await modelManager.download(repo)
                    }
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
                    Task {
                        applyHFEndpoint(hfEndpoint)
                        try? await modelManager.download(repo)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func applyHFEndpoint(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        Task { await modelManager.endpointURL = url }
    }

    private func startObserving() {
        stateTask?.cancel()
        refreshModelStates()

        stateTask = Task {
            for await (repo, state) in modelManager.stateChanges {
                await MainActor.run { modelStates[repo] = state }
            }
        }
    }

    private func refreshModelStates() {
        Task {
            for repo in allRepos {
                let state = await modelManager.state(for: repo)
                await MainActor.run { modelStates[repo] = state }
            }
        }
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.voiceSTTModel = sttModel
        prefs.voiceTTSModel = ttsModel
        prefs.voiceVADModel = vadModel
        prefs.hfEndpoint = hfEndpoint
    }
}
