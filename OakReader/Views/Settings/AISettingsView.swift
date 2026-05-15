import SwiftUI
import OakAgent
import OakVoiceAI

struct AISettingsView: View {
    // MARK: - Sidebar Category

    enum Category: String, Hashable, Identifiable {
        case chat, voiceLLM
        case embedding, transcribe, tts, vad
        case agentTools

        var id: String { rawValue }

        var label: String {
            switch self {
            case .chat: "Chat"
            case .voiceLLM: "Voice Chat LLM"
            case .embedding: "Embedding"
            case .transcribe: "Transcribe"
            case .tts: "TTS"
            case .vad: "VAD"
            case .agentTools: "Tools"
            }
        }

        var icon: String {
            switch self {
            case .chat: "bubble.left"
            case .voiceLLM: "mic.badge.plus"
            case .embedding: "magnifyingglass"
            case .transcribe: "mic"
            case .tts: "speaker.wave.2"
            case .vad: "waveform"
            case .agentTools: "wrench.and.screwdriver"
            }
        }
    }

    private static let llmCategories: [Category] = [.chat, .voiceLLM]
    private static let onDeviceCategories: [Category] = [.embedding, .transcribe, .tts, .vad]
    private static let agentCategories: [Category] = [.agentTools]

    // MARK: - State

    @State private var selectedCategory: Category = .chat

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
    @State private var vadModel: String

    // STT/TTS provider type
    @State private var sttProvider: String
    @State private var ttsProvider: String
    @State private var elevenLabsVoiceId: String
    @State private var elevenLabsTTSModelId: String

    // Agent tools
    @State private var agentToolsEnabled: Bool
    @State private var agentReadFileEnabled: Bool
    @State private var agentWriteFileEnabled: Bool
    @State private var agentPermissionLevel: AgentPermissionLevel

    // Thinking
    @State private var thinkingBudget: Int

    // Model download states (shared with LocalModelsSettingsView)
    let modelStates: SharedModelStates

    private let store = ConfiguredProviderStore.shared
    private var modelManager: ModelManager { ModelManager.shared }

    // MARK: - Init

    init(modelStates: SharedModelStates) {
        self.modelStates = modelStates
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard

        // Chat
        let pid = prefs.aiProviderId
        _chatProviderId = State(initialValue: pid)
        let defaultModel = ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
        _chatModel = State(initialValue: prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel)

        // Voice Chat LLM – empty model means "use chat default"
        let vlm = prefs.voiceLLMModel
        _voiceLLMUseChatDefault = State(initialValue: vlm.isEmpty)
        _voiceLLMModel = State(initialValue: vlm.isEmpty ? defaultModel : vlm)
        // Derive provider from model
        let vlmProvider = Self.providerForModel(vlm.isEmpty ? (prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel) : vlm) ?? pid
        _voiceLLMProviderId = State(initialValue: vlmProvider)

        // On-device models
        let defaultSTT = KnownModels.stt.first?.repo ?? ""
        let defaultTTS = KnownModels.tts.first?.repo ?? ""
        let defaultVAD = KnownModels.vad.first?.repo ?? ""
        let defaultEmbedding = KnownModels.embedding.first?.repo ?? ""
        _embeddingModel = State(initialValue: prefs.embeddingModel.isEmpty ? defaultEmbedding : prefs.embeddingModel)
        _sttModel = State(initialValue: prefs.voiceSTTModel.isEmpty ? defaultSTT : prefs.voiceSTTModel)
        _ttsModel = State(initialValue: prefs.voiceTTSModel.isEmpty ? defaultTTS : prefs.voiceTTSModel)
        _vadModel = State(initialValue: prefs.voiceVADModel.isEmpty ? defaultVAD : prefs.voiceVADModel)

        // STT/TTS provider type
        _sttProvider = State(initialValue: prefs.voiceSTTProvider)
        _ttsProvider = State(initialValue: prefs.voiceTTSProvider)
        _elevenLabsVoiceId = State(initialValue: prefs.elevenLabsVoiceId)
        _elevenLabsTTSModelId = State(initialValue: prefs.elevenLabsTTSModelId)

        // Agent tools
        _agentToolsEnabled = State(initialValue: prefs.agentToolsEnabled)
        _agentReadFileEnabled = State(initialValue: prefs.agentReadFileEnabled)
        _agentWriteFileEnabled = State(initialValue: prefs.agentWriteFileEnabled)
        _agentPermissionLevel = State(initialValue: prefs.agentPermissionLevel)

        // Thinking
        _thinkingBudget = State(initialValue: prefs.thinkingBudget)
    }

    /// Find which configured provider owns a given model ID.
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
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)

            Divider()

            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { modelStates.refresh(repos: allRepos) }
        .onDisappear { save() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("LLM")
                ForEach(Self.llmCategories) { cat in
                    sidebarRow(cat)
                }

                sectionHeader("On-Device")
                ForEach(Self.onDeviceCategories) { cat in
                    sidebarRow(cat)
                }

                sectionHeader("Agent")
                ForEach(Self.agentCategories) { cat in
                    sidebarRow(cat)
                }
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

    private func sidebarRow(_ category: Category) -> some View {
        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)

                Text(category.label)
                    .font(.body)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedCategory == category ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private var detailPanel: some View {
        switch selectedCategory {
        case .chat: chatPanel
        case .voiceLLM: voiceLLMPanel
        case .embedding: localModelPanel(binding: $embeddingModel, knownModels: KnownModels.embedding)
        case .transcribe: transcribePanel
        case .tts: ttsPanel
        case .vad: localModelPanel(binding: $vadModel, knownModels: KnownModels.vad)
        case .agentTools: agentToolsPanel
        }
    }

    // MARK: - Chat Panel

    private var chatPanel: some View {
        Form {
            Section("Default LLM") {
                if store.configuredLLMProviders.isEmpty {
                    Text("Configure a provider in AI Providers to select a default LLM.")
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

            // Thinking budget — only shown when the selected model supports reasoning
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
        .formStyle(.grouped)
    }

    // MARK: - Voice Chat LLM Panel

    private var voiceLLMPanel: some View {
        Form {
            Section("Voice Chat LLM") {
                Toggle("Use Chat default", isOn: $voiceLLMUseChatDefault)

                if voiceLLMUseChatDefault {
                    chatDefaultLabel
                } else {
                    llmPickers(providerId: $voiceLLMProviderId, model: $voiceLLMModel)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Transcribe Panel

    private var transcribePanel: some View {
        Form {
            Section("Transcribe Provider") {
                Picker("Provider", selection: $sttProvider) {
                    ForEach(VoiceProviderType.allCases, id: \.rawValue) { type in
                        if type == .elevenLabs && !store.isElevenLabsConfigured {
                            EmptyView()
                        } else {
                            Text(type.displayName).tag(type.rawValue)
                        }
                    }
                }
            }

            if sttProvider == VoiceProviderType.onDevice.rawValue {
                Section("On-Device Model") {
                    Picker("Model", selection: $sttModel) {
                        ForEach(KnownModels.stt) { option in
                            Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                        }
                    }
                }

                Section("Status") {
                    modelStatusRow(repo: sttModel)
                    if let option = KnownModels.stt.first(where: { $0.repo == sttModel }) {
                        LabeledContent("Size", value: option.sizeLabel)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - TTS Panel

    private var ttsPanel: some View {
        Form {
            Section("TTS Provider") {
                Picker("Provider", selection: $ttsProvider) {
                    ForEach(VoiceProviderType.allCases, id: \.rawValue) { type in
                        if type == .elevenLabs && !store.isElevenLabsConfigured {
                            EmptyView()
                        } else {
                            Text(type.displayName).tag(type.rawValue)
                        }
                    }
                }
            }

            if ttsProvider == VoiceProviderType.onDevice.rawValue {
                Section("On-Device Model") {
                    Picker("Model", selection: $ttsModel) {
                        ForEach(KnownModels.tts) { option in
                            Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                        }
                    }
                }

                Section("Status") {
                    modelStatusRow(repo: ttsModel)
                    if let option = KnownModels.tts.first(where: { $0.repo == ttsModel }) {
                        LabeledContent("Size", value: option.sizeLabel)
                    }
                }
            }

            if ttsProvider == VoiceProviderType.elevenLabs.rawValue && store.isElevenLabsConfigured {
                Section("ElevenLabs Settings") {
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
        .formStyle(.grouped)
    }

    // MARK: - Local Model Panel (Embedding / VAD)

    private func localModelPanel(binding: Binding<String>, knownModels: [ModelOption]) -> some View {
        let repo = binding.wrappedValue
        return Form {
            Section("Model") {
                Picker("Model", selection: binding) {
                    ForEach(knownModels) { option in
                        Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                    }
                }
            }

            Section("Status") {
                modelStatusRow(repo: repo)
                if let option = knownModels.first(where: { $0.repo == repo }) {
                    LabeledContent("Size", value: option.sizeLabel)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Agent Tools Panel

    private var agentToolsPanel: some View {
        Form {
            Section("Agent Tools") {
                Toggle("Enable Agent Tools", isOn: $agentToolsEnabled)

                Toggle("Read File", isOn: $agentReadFileEnabled)
                    .disabled(!agentToolsEnabled)

                Toggle("Write File", isOn: $agentWriteFileEnabled)
                    .disabled(!agentToolsEnabled)

                Picker("Confirmation", selection: $agentPermissionLevel) {
                    ForEach(AgentPermissionLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .disabled(!agentToolsEnabled)

                Text(agentPermissionLevel.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shared Components

    /// Provider + Model pickers for LLM capabilities.
    @ViewBuilder
    private func llmPickers(providerId: Binding<String>, model: Binding<String>) -> some View {
        if store.configuredLLMProviders.isEmpty {
            Text("Configure a provider in AI Providers first.")
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

    /// Label showing the current Chat default provider + model.
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

    private var allRepos: [String] { [sttModel, ttsModel, vadModel, embeddingModel] }

    private func save() {
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard

        // Chat
        prefs.aiProviderId = chatProviderId
        prefs.aiModel = chatModel

        // Voice Chat LLM
        prefs.voiceLLMModel = voiceLLMUseChatDefault ? "" : voiceLLMModel

        // On-device
        prefs.embeddingModel = embeddingModel
        prefs.voiceSTTModel = sttModel
        prefs.voiceTTSModel = ttsModel
        prefs.voiceVADModel = vadModel

        // STT/TTS providers
        prefs.voiceSTTProvider = sttProvider
        prefs.voiceTTSProvider = ttsProvider
        prefs.elevenLabsVoiceId = elevenLabsVoiceId
        prefs.elevenLabsTTSModelId = elevenLabsTTSModelId

        // Agent tools
        prefs.agentToolsEnabled = agentToolsEnabled
        prefs.agentReadFileEnabled = agentReadFileEnabled
        prefs.agentWriteFileEnabled = agentWriteFileEnabled
        prefs.agentPermissionLevel = agentPermissionLevel

        // Thinking
        prefs.thinkingBudget = thinkingBudget
    }
}
