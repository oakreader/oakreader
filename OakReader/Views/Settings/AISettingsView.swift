import SwiftUI
import OakAgent
import OakVoice

struct AISettingsView: View {
    /// Sentinel ID for ElevenLabs (not in ProviderRegistry).
    static let elevenLabsId = "__elevenlabs__"

    // MARK: - State

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

    // Voice providers
    @State private var ttsProvider: String
    @State private var sttProvider: String
    @State private var elevenLabsVoiceId: String
    @State private var elevenLabsTTSModelId: String
    @State private var openAITTSVoice: String
    @State private var geminiTTSVoice: String
    @State private var fishAudioAPIKey: String
    @State private var fishAudioReferenceId: String

    // Thinking
    @State private var thinkingBudget: Int

    private let openAIVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
    private let geminiVoices = ["Kore", "Puck", "Zephyr", "Charon", "Fenrir", "Aoede", "Leda", "Orus"]

    // MARK: - Init

    init() {
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

        // Voice providers
        _ttsProvider = State(initialValue: prefs.voiceTTSProvider)
        _sttProvider = State(initialValue: prefs.voiceSTTProvider)
        _elevenLabsVoiceId = State(initialValue: prefs.elevenLabsVoiceId)
        _elevenLabsTTSModelId = State(initialValue: prefs.elevenLabsTTSModelId)
        _openAITTSVoice = State(initialValue: prefs.openAITTSVoice)
        _geminiTTSVoice = State(initialValue: prefs.geminiTTSVoice)
        _fishAudioAPIKey = State(initialValue: prefs.fishAudioAPIKey)
        _fishAudioReferenceId = State(initialValue: prefs.fishAudioReferenceId)

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
            }
            .formStyle(.grouped)
            .navigationTitle("AI")
            .navigationDestination(for: String.self) { providerId in
                AIProviderConfigView(providerId: providerId, store: store)
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
                    Text(type.displayName).tag(type.rawValue)
                }
            }
            providerCredentialRow(for: VoiceProviderType(rawValue: sttProvider) ?? .elevenLabs)
        }
    }

    // MARK: - TTS Section

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
                if store.isElevenLabsConfigured {
                    TextField("Voice ID", text: $elevenLabsVoiceId)
                        .textFieldStyle(.roundedBorder)
                    Picker("TTS Model", selection: $elevenLabsTTSModelId) {
                        Text("Turbo v2.5 (fastest)").tag("eleven_turbo_v2_5")
                        Text("Flash v2.5 (fast)").tag("eleven_flash_v2_5")
                        Text("Multilingual v2 (quality)").tag("eleven_multilingual_v2")
                    }
                } else {
                    missingCredentialHint(.elevenLabs)
                }
            case .openAI:
                Picker("Voice", selection: $openAITTSVoice) {
                    ForEach(openAIVoices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                providerCredentialRow(for: .openAI)
            case .gemini:
                Picker("Voice", selection: $geminiTTSVoice) {
                    ForEach(geminiVoices, id: \.self) { Text($0).tag($0) }
                }
                providerCredentialRow(for: .gemini)
            case .fishAudio:
                fishAudioFields
            }
        }
    }

    // MARK: - Provider credential helpers

    /// Whether a voice provider has the credentials it needs.
    private func isConfigured(_ type: VoiceProviderType) -> Bool {
        switch type {
        case .elevenLabs: return store.isElevenLabsConfigured
        case .fishAudio: return !fishAudioAPIKey.isEmpty
        case .openAI: return store.configuredLLMProviderIds.contains("openai")
        case .gemini: return store.configuredLLMProviderIds.contains("google")
        }
    }

    @ViewBuilder
    private func providerCredentialRow(for type: VoiceProviderType) -> some View {
        switch type {
        case .fishAudio:
            fishAudioFields
        case .elevenLabs:
            if !store.isElevenLabsConfigured { missingCredentialHint(.elevenLabs) }
        case .openAI, .gemini:
            if !isConfigured(type) { missingCredentialHint(type) }
        }
    }

    @ViewBuilder
    private var fishAudioFields: some View {
        SecureField("Fish Audio API Key", text: $fishAudioAPIKey)
            .textFieldStyle(.roundedBorder)
        TextField("Voice Reference ID (optional)", text: $fishAudioReferenceId)
            .textFieldStyle(.roundedBorder)
    }

    private func missingCredentialHint(_ type: VoiceProviderType) -> some View {
        Label(missingCredentialMessage(type), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func missingCredentialMessage(_ type: VoiceProviderType) -> String {
        switch type {
        case .elevenLabs: return "Add ElevenLabs in Providers above to use it."
        case .openAI: return "Add an OpenAI provider in Providers above; its API key is reused here."
        case .gemini: return "Add a Google Gemini provider in Providers above; its API key is reused here."
        case .fishAudio: return "Enter a Fish Audio API key above."
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

    // MARK: - Helpers

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    private func save() {
        let prefs = Preferences.shared

        // Chat
        prefs.aiProviderId = chatProviderId
        prefs.aiModel = chatModel

        // Voice Chat LLM
        prefs.voiceLLMModel = voiceLLMUseChatDefault ? "" : voiceLLMModel

        // Voice providers
        prefs.voiceTTSProvider = ttsProvider
        prefs.voiceSTTProvider = sttProvider
        prefs.elevenLabsVoiceId = elevenLabsVoiceId
        prefs.elevenLabsTTSModelId = elevenLabsTTSModelId
        prefs.openAITTSVoice = openAITTSVoice
        prefs.geminiTTSVoice = geminiTTSVoice
        prefs.fishAudioAPIKey = fishAudioAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.fishAudioReferenceId = fishAudioReferenceId.trimmingCharacters(in: .whitespacesAndNewlines)

        // Thinking
        prefs.thinkingBudget = thinkingBudget
    }
}
