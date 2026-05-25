import SwiftUI
import OakAgent
import OakVoice

struct AISettingsView: View {
    /// Sentinel ID for ElevenLabs (not in ProviderRegistry).
    static let elevenLabsId = "__elevenlabs__"
    /// Sentinel ID for Local Models.
    static let localModelsId = "__local_models__"

    // MARK: - State

    let modelStates: SharedModelStates
    @State private var store = ConfiguredProviderStore.shared
    @State private var navigationPath = NavigationPath()
    @State private var showAddProviderSheet = false

    // Chat LLM
    @State private var chatProviderId: String
    @State private var chatModel: String

    // Voice Chat LLM
    @State private var voiceLLMUseChatDefault: Bool
    @State private var voiceLLMProviderId: String
    @State private var voiceLLMModel: String

    // On-Device models
    @State private var embeddingModel: String
    @State private var sttModel: String
    @State private var ttsModel: String

    // STT/TTS provider type
    @State private var sttProvider: String
    @State private var ttsProvider: String
    @State private var elevenLabsVoiceId: String
    @State private var elevenLabsTTSModelId: String

    // Thinking
    @State private var thinkingBudget: Int

    private var modelManager: ModelManager { ModelManager.shared }

    // MARK: - Init

    init(modelStates: SharedModelStates) {
        self.modelStates = modelStates
        let prefs = Preferences.shared

        // Chat
        let pid = prefs.aiProviderId
        _chatProviderId = State(initialValue: pid)
        let defaultModel = ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
        _chatModel = State(initialValue: prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel)

        // Voice Chat LLM
        let vlm = prefs.voiceLLMModel
        _voiceLLMUseChatDefault = State(initialValue: vlm.isEmpty)
        _voiceLLMModel = State(initialValue: vlm.isEmpty ? defaultModel : vlm)
        let vlmProvider = Self.providerForModel(vlm.isEmpty ? (prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel) : vlm) ?? pid
        _voiceLLMProviderId = State(initialValue: vlmProvider)

        // On-device models
        let defaultSTT = KnownModels.stt.first?.repo ?? ""
        let defaultTTS = KnownModels.tts.first?.repo ?? ""
        let defaultEmbedding = KnownModels.embedding.first?.repo ?? ""
        _embeddingModel = State(initialValue: prefs.embeddingModel.isEmpty ? defaultEmbedding : prefs.embeddingModel)
        _sttModel = State(initialValue: prefs.voiceSTTModel.isEmpty ? defaultSTT : prefs.voiceSTTModel)
        _ttsModel = State(initialValue: prefs.voiceTTSModel.isEmpty ? defaultTTS : prefs.voiceTTSModel)

        // STT/TTS provider type
        _sttProvider = State(initialValue: prefs.voiceSTTProvider)
        _ttsProvider = State(initialValue: prefs.voiceTTSProvider)
        _elevenLabsVoiceId = State(initialValue: prefs.elevenLabsVoiceId)
        _elevenLabsTTSModelId = State(initialValue: prefs.elevenLabsTTSModelId)

        // Thinking
        _thinkingBudget = State(initialValue: prefs.thinkingBudget)
    }

    private static func providerForModel(_ modelId: String) -> String? {
        for provider in ConfiguredProviderStore.shared.configuredLLMProviders {
            if provider.models.contains(where: { $0.id == modelId }) {
                return provider.id
            }
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                providersSection
                chatSection
                thinkingSection
                voiceChatSection
                transcribeSection
                ttsSection
                embeddingSection
            }
            .formStyle(.grouped)
            .navigationTitle("AI")
            .navigationDestination(for: String.self) { providerId in
                if providerId == Self.localModelsId {
                    LocalModelsSettingsView(modelStates: modelStates)
                } else {
                    AIProviderConfigView(providerId: providerId, store: store)
                }
            }
            .sheet(isPresented: $showAddProviderSheet) {
                AddProviderSheet(store: store) { selectedId in
                    showAddProviderSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        navigationPath.append(selectedId)
                    }
                }
            }
        }
        .onAppear { modelStates.refresh(repos: allRepos) }
        .onDisappear { save() }
    }

    // MARK: - Providers Section

    @ViewBuilder
    private var providersSection: some View {
        Section("Providers") {
            ForEach(store.configuredLLMProviders) { provider in
                NavigationLink(value: provider.id) {
                    HStack(spacing: 10) {
                        Image("provider-\(provider.id)")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5))

                        Text(provider.displayName)

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    }
                }
            }

            if store.isElevenLabsConfigured {
                NavigationLink(value: Self.elevenLabsId) {
                    HStack(spacing: 10) {
                        Image("provider-elevenlabs")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5))

                        Text("ElevenLabs")

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    }
                }
            }

            NavigationLink(value: Self.localModelsId) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)

                    Text("Local Models")
                }
            }

            Button {
                showAddProviderSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                        .frame(width: 24, height: 24)

                    Text("Add Provider...")
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Chat Section

    @ViewBuilder
    private var chatSection: some View {
        Section("Chat") {
            if store.configuredLLMProviders.isEmpty {
                Text("Add a provider above to select a default LLM.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $chatProviderId) {
                    ForEach(store.configuredLLMProviders) { p in
                        Text(p.displayName).tag(p.id)
                    }
                }
                .onChange(of: chatProviderId) { _, newValue in
                    chatModel = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
                }

                if let provider = ProviderRegistry.shared.provider(for: chatProviderId) {
                    Picker("Model", selection: $chatModel) {
                        ForEach(provider.models) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                }

                if let provider = ProviderRegistry.shared.provider(for: chatProviderId),
                   let info = provider.models.first(where: { $0.id == chatModel }) {
                    LabeledContent("Context Window", value: formatTokens(info.contextWindow))
                    LabeledContent("Max Output", value: formatTokens(info.maxTokens))
                    LabeledContent("Vision", value: info.supportsVision ? "Yes" : "No")
                    LabeledContent("Reasoning", value: info.reasoning ? "Yes" : "No")
                }
            }
        }
    }

    // MARK: - Thinking Section

    @ViewBuilder
    private var thinkingSection: some View {
        if let provider = ProviderRegistry.shared.provider(for: chatProviderId),
           let info = provider.models.first(where: { $0.id == chatModel }),
           info.reasoning {
            Section("Extended Thinking") {
                Stepper(
                    "Budget: \(formatTokens(thinkingBudget)) tokens",
                    value: $thinkingBudget,
                    in: 1000...128000,
                    step: 1000
                )

                Text("Token budget for model reasoning. Higher values allow deeper thinking but increase latency and cost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Voice Chat Section

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

    // MARK: - Transcribe Section

    @ViewBuilder
    private var transcribeSection: some View {
        Section("Transcribe") {
            Picker("Provider", selection: $sttProvider) {
                ForEach(VoiceProviderType.allCases, id: \.rawValue) { type in
                    if type == .elevenLabs && !store.isElevenLabsConfigured {
                        EmptyView()
                    } else {
                        Text(type.displayName).tag(type.rawValue)
                    }
                }
            }

            if sttProvider == VoiceProviderType.onDevice.rawValue {
                Picker("Model", selection: $sttModel) {
                    ForEach(KnownModels.stt) { option in
                        Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                    }
                }

                modelStatusRow(repo: sttModel)

                if let option = KnownModels.stt.first(where: { $0.repo == sttModel }) {
                    LabeledContent("Size", value: option.sizeLabel)
                }
            }
        }
    }

    // MARK: - TTS Section

    @ViewBuilder
    private var ttsSection: some View {
        Section("TTS") {
            Picker("Provider", selection: $ttsProvider) {
                ForEach(VoiceProviderType.allCases, id: \.rawValue) { type in
                    if type == .elevenLabs && !store.isElevenLabsConfigured {
                        EmptyView()
                    } else {
                        Text(type.displayName).tag(type.rawValue)
                    }
                }
            }

            if ttsProvider == VoiceProviderType.onDevice.rawValue {
                Picker("Model", selection: $ttsModel) {
                    ForEach(KnownModels.tts) { option in
                        Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                    }
                }

                modelStatusRow(repo: ttsModel)

                if let option = KnownModels.tts.first(where: { $0.repo == ttsModel }) {
                    LabeledContent("Size", value: option.sizeLabel)
                }
            }

            if ttsProvider == VoiceProviderType.elevenLabs.rawValue && store.isElevenLabsConfigured {
                TextField("Voice ID", text: $elevenLabsVoiceId)
                    .textFieldStyle(.roundedBorder)

                Picker("TTS Model", selection: $elevenLabsTTSModelId) {
                    Text("Turbo v2.5 (fastest)").tag("eleven_turbo_v2_5")
                    Text("Flash v2.5 (fast)").tag("eleven_flash_v2_5")
                    Text("Multilingual v2 (quality)").tag("eleven_multilingual_v2")
                }
            }
        }
    }

    // MARK: - Embedding Section

    @ViewBuilder
    private var embeddingSection: some View {
        Section("Embedding") {
            Picker("Model", selection: $embeddingModel) {
                ForEach(KnownModels.embedding) { option in
                    Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                }
            }

            modelStatusRow(repo: embeddingModel)

            if let option = KnownModels.embedding.first(where: { $0.repo == embeddingModel }) {
                LabeledContent("Size", value: option.sizeLabel)
            }
        }
    }

    // MARK: - Shared Components

    @ViewBuilder
    private func llmPickers(providerId: Binding<String>, model: Binding<String>) -> some View {
        if store.configuredLLMProviders.isEmpty {
            Text("Add a provider above to select a model.")
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

    // MARK: - Model Status Row

    @ViewBuilder
    private func modelStatusRow(repo: String) -> some View {
        let state = modelStates.states[repo] ?? .notDownloaded
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

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    private var allRepos: [String] { [sttModel, ttsModel, embeddingModel] }

    private func save() {
        let prefs = Preferences.shared

        // Chat
        prefs.aiProviderId = chatProviderId
        prefs.aiModel = chatModel

        // Voice Chat LLM
        prefs.voiceLLMModel = voiceLLMUseChatDefault ? "" : voiceLLMModel

        // On-device
        prefs.embeddingModel = embeddingModel
        prefs.voiceSTTModel = sttModel
        prefs.voiceTTSModel = ttsModel

        // STT/TTS providers
        prefs.voiceSTTProvider = sttProvider
        prefs.voiceTTSProvider = ttsProvider
        prefs.elevenLabsVoiceId = elevenLabsVoiceId
        prefs.elevenLabsTTSModelId = elevenLabsTTSModelId

        // Thinking
        prefs.thinkingBudget = thinkingBudget
    }
}
