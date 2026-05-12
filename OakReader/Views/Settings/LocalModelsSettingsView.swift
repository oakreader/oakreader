import SwiftUI
import OakVoiceAI

struct LocalModelsSettingsView: View {
    // MARK: - Sidebar selection

    enum SidebarItem: Hashable {
        case category(ModelCategory)
        case hfEndpoint
    }

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

        var icon: String {
            switch self {
            case .embedding: "magnifyingglass"
            case .stt: "mic"
            case .tts: "speaker.wave.2"
            case .vad: "waveform"
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

    @State private var selectedItem: SidebarItem? = .category(.embedding)
    @State private var sttModel: String
    @State private var ttsModel: String
    @State private var vadModel: String
    @State private var embeddingModel: String
    @State private var hfEndpoint: String

    @State private var modelStates: [String: ModelManager.ModelState] = [:]
    @State private var stateTask: Task<Void, Never>?

    private var modelManager: ModelManager { ModelManager.shared }

    init() {
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
            switch modelStates[repo] {
            case .downloaded, .ready: return true
            default: return false
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)

            Divider()

            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Models")

                ForEach(ModelCategory.allCases) { category in
                    let repo = selectedRepo(for: category)
                    let downloaded = isDownloaded(repo: repo)
                    listRow(
                        item: .category(category),
                        sfSymbol: category.icon,
                        title: category.label,
                        isConfigured: downloaded
                    )
                }

                sectionHeader("Settings")

                listRow(
                    item: .hfEndpoint,
                    sfSymbol: "network",
                    title: "HuggingFace",
                    isConfigured: true
                )

                Divider()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                downloadAllButton
                    .padding(.horizontal, 8)
            }
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func listRow(item: SidebarItem, sfSymbol: String, title: String, isConfigured: Bool) -> some View {
        Button {
            selectedItem = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sfSymbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)

                Text(title)
                    .font(.body)
                    .foregroundStyle(isConfigured ? .primary : .secondary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isConfigured ? Color.green : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedItem == item ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private var downloadAllButton: some View {
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
                    .font(.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .disabled(allDownloaded)
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private var detailPanel: some View {
        switch selectedItem {
        case .category(let category):
            categoryDetailView(category)
        case .hfEndpoint:
            hfEndpointView
        case nil:
            ContentUnavailableView(
                "Select an Item",
                systemImage: "cpu",
                description: Text("Choose a model category from the list to configure it.")
            )
        }
    }

    private func categoryDetailView(_ category: ModelCategory) -> some View {
        let binding = modelBinding(for: category)
        let repo = binding.wrappedValue
        let state = modelStates[repo] ?? .notDownloaded
        let currentOption = category.knownModels.first { $0.repo == repo }

        return Form {
            Section {
                Picker("Model", selection: binding) {
                    ForEach(category.knownModels) { option in
                        Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                    }
                }
            }

            Section("Status") {
                modelStatusRow(repo: repo)

                if let option = currentOption {
                    LabeledContent("Size", value: option.sizeLabel)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hfEndpointView: some View {
        Form {
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

    private func selectedRepo(for category: ModelCategory) -> String {
        switch category {
        case .embedding: embeddingModel
        case .stt: sttModel
        case .tts: ttsModel
        case .vad: vadModel
        }
    }

    private func modelBinding(for category: ModelCategory) -> Binding<String> {
        switch category {
        case .embedding: $embeddingModel
        case .stt: $sttModel
        case .tts: $ttsModel
        case .vad: $vadModel
        }
    }

    private func isDownloaded(repo: String) -> Bool {
        switch modelStates[repo] {
        case .downloaded, .ready: return true
        default: return false
        }
    }

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
        prefs.embeddingModel = embeddingModel
        prefs.hfEndpoint = hfEndpoint
    }
}
