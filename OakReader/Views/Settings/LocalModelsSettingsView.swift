import SwiftUI
import OakVoice

struct LocalModelsSettingsView: View {
    enum ModelCategory: String, CaseIterable, Identifiable {
        case embedding, stt, tts, vad

        var id: String { rawValue }

        var label: String {
            switch self {
            case .embedding: "Embedding"
            case .stt: "Speech-to-Text"
            case .tts: "Text-to-Speech"
            case .vad: "Voice Activity Detection"
            }
        }

        var knownModels: [ModelOption] {
            switch self {
            case .embedding: KnownModels.embedding
            case .stt: KnownModels.stt
            case .tts: KnownModels.tts
            case .vad: KnownModels.vad
            }
        }
    }

    // MARK: - State

    @State private var sttModel: String
    @State private var ttsModel: String
    @State private var vadModel: String
    @State private var embeddingModel: String
    @State private var hfEndpoint: String

    let modelStates: SharedModelStates

    private var modelManager: ModelManager { ModelManager.shared }

    init(modelStates: SharedModelStates) {
        self.modelStates = modelStates
        let prefs = Preferences.shared
        let defaultSTT = KnownModels.stt.first?.repo ?? ""
        let defaultTTS = KnownModels.tts.first?.repo ?? ""
        let defaultVAD = KnownModels.vad.first?.repo ?? ""
        let defaultEmbedding = KnownModels.embedding.first?.repo ?? ""
        _sttModel = State(initialValue: prefs.voiceSTTModel.isEmpty ? defaultSTT : prefs.voiceSTTModel)
        _ttsModel = State(initialValue: prefs.voiceTTSModel.isEmpty ? defaultTTS : prefs.voiceTTSModel)
        _vadModel = State(initialValue: prefs.voiceVADModel.isEmpty ? defaultVAD : prefs.voiceVADModel)
        _embeddingModel = State(initialValue: prefs.embeddingModel.isEmpty ? defaultEmbedding : prefs.embeddingModel)
        _hfEndpoint = State(initialValue: prefs.hfEndpoint)
    }

    private var allRepos: [String] { [sttModel, ttsModel, vadModel, embeddingModel] }

    private var allDownloaded: Bool {
        allRepos.allSatisfy { repo in
            switch modelStates.states[repo] {
            case .downloaded, .ready: return true
            default: return false
            }
        }
    }

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        applyHFEndpoint(hfEndpoint)
                        let config = VoiceModelConfig(
                            sttModel: sttModel,
                            ttsModel: ttsModel,
                            vadModel: vadModel
                        )
                        try? await modelManager.downloadAll(config)
                    }
                } label: {
                    HStack {
                        Image(systemName: allDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(allDownloaded ? .green : .accentColor)
                        Text(allDownloaded ? "All Downloaded" : "Download All")
                    }
                }
                .disabled(allDownloaded)
            }

            ForEach(ModelCategory.allCases) { category in
                categorySection(category)
            }

            Section("HuggingFace Endpoint") {
                TextField("Endpoint URL", text: $hfEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: hfEndpoint) { _, newValue in
                        applyHFEndpoint(newValue)
                    }

                Text("Leave empty for default (huggingface.co). Use https://hf-mirror.com if downloads fail due to network restrictions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Local Models")
        .onAppear {
            modelStates.refresh(repos: allRepos)
            applyHFEndpoint(hfEndpoint)
        }
        .onDisappear { save() }
        .onChange(of: allRepos) { _, _ in
            modelStates.refresh(repos: allRepos)
        }
    }

    // MARK: - Category Section

    @ViewBuilder
    private func categorySection(_ category: ModelCategory) -> some View {
        let binding = modelBinding(for: category)
        let repo = binding.wrappedValue

        Section(category.label) {
            Picker("Model", selection: binding) {
                ForEach(category.knownModels) { option in
                    Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                }
            }

            modelStatusRow(repo: repo)

            if let option = category.knownModels.first(where: { $0.repo == repo }) {
                LabeledContent("Size", value: option.sizeLabel)
            }
        }
    }

    // MARK: - Model Status Row

    @ViewBuilder
    private func modelStatusRow(repo: String) -> some View {
        let state: ModelManager.ModelState = modelStates.states[repo] ?? .notDownloaded
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

    private func modelBinding(for category: ModelCategory) -> Binding<String> {
        switch category {
        case .embedding: $embeddingModel
        case .stt: $sttModel
        case .tts: $ttsModel
        case .vad: $vadModel
        }
    }

    private func applyHFEndpoint(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        Task { await modelManager.endpointURL = url }
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.voiceSTTModel = sttModel
        prefs.voiceTTSModel = ttsModel
        prefs.voiceVADModel = vadModel
        prefs.embeddingModel = embeddingModel
        prefs.hfEndpoint = hfEndpoint
    }
}
