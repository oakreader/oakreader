import SwiftUI
import OakReaderAI
import VoiceAgentKit

// MARK: - Provider Config View (Right Panel)

struct AIProviderConfigView: View {
    let providerId: String
    let store: ConfiguredProviderStore

    var body: some View {
        if providerId == AIProvidersSettingsView.defaultsId {
            DefaultsConfigView(store: store)
        } else {
            ProviderDetailView(providerId: providerId, store: store)
        }
    }
}

// MARK: - Defaults Config View

/// Global LLM/TTS/ASR/Agent settings panel.
private struct DefaultsConfigView: View {
    let store: ConfiguredProviderStore

    @State private var providerId: String
    @State private var model: String
    @State private var sttProvider: String
    @State private var ttsProvider: String
    @State private var elevenLabsVoiceId: String
    @State private var elevenLabsTTSModelId: String
    @State private var agentToolsEnabled: Bool
    @State private var agentReadFileEnabled: Bool
    @State private var agentWriteFileEnabled: Bool
    @State private var agentRequireConfirmation: Bool

    init(store: ConfiguredProviderStore) {
        self.store = store
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        _providerId = State(initialValue: pid)
        let defaultModel = ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
        _model = State(initialValue: prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel)
        _sttProvider = State(initialValue: prefs.voiceSTTProvider)
        _ttsProvider = State(initialValue: prefs.voiceTTSProvider)
        _elevenLabsVoiceId = State(initialValue: prefs.elevenLabsVoiceId)
        _elevenLabsTTSModelId = State(initialValue: prefs.elevenLabsTTSModelId)
        _agentToolsEnabled = State(initialValue: prefs.agentToolsEnabled)
        _agentReadFileEnabled = State(initialValue: prefs.agentReadFileEnabled)
        _agentWriteFileEnabled = State(initialValue: prefs.agentWriteFileEnabled)
        _agentRequireConfirmation = State(initialValue: prefs.agentRequireConfirmation)
    }

    private var selectedProvider: ProviderInfo? {
        ProviderRegistry.shared.provider(for: providerId)
    }

    private var selectedModelInfo: ModelInfo? {
        selectedProvider?.models.first { $0.id == model }
    }

    var body: some View {
        Form {
            llmSection
            ttsSection
            asrSection
            agentToolsSection
        }
        .formStyle(.grouped)
        .onDisappear { save() }
    }

    // MARK: - LLM

    private var llmSection: some View {
        Section("Default LLM") {
            if store.configuredLLMProviders.isEmpty {
                Text("Configure a provider to select a default LLM.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $providerId) {
                    ForEach(store.configuredLLMProviders) { p in
                        Text(p.displayName).tag(p.id)
                    }
                }
                .onChange(of: providerId) { _, newValue in
                    model = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
                }

                if let provider = selectedProvider {
                    Picker("Model", selection: $model) {
                        ForEach(provider.models) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                }

                if let info = selectedModelInfo {
                    LabeledContent("Context Window", value: formatTokens(info.contextWindow))
                    LabeledContent("Max Output", value: formatTokens(info.maxTokens))
                    LabeledContent("Vision", value: info.supportsVision ? "Yes" : "No")
                    LabeledContent("Reasoning", value: info.reasoning ? "Yes" : "No")
                }
            }
        }
    }

    // MARK: - TTS

    private var ttsSection: some View {
        Section("TTS") {
            Picker("Provider", selection: $ttsProvider) {
                ForEach(VoiceProviderType.allCases, id: \.rawValue) { type in
                    if type == .elevenLabs && !store.isElevenLabsConfigured {
                        // Skip unconfigured ElevenLabs
                    } else {
                        Text(type.displayName).tag(type.rawValue)
                    }
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

    // MARK: - ASR

    private var asrSection: some View {
        Section("ASR") {
            Picker("Provider", selection: $sttProvider) {
                ForEach(VoiceProviderType.allCases, id: \.rawValue) { type in
                    if type == .elevenLabs && !store.isElevenLabsConfigured {
                        // Skip unconfigured ElevenLabs
                    } else {
                        Text(type.displayName).tag(type.rawValue)
                    }
                }
            }
        }
    }

    // MARK: - Agent Tools

    private var agentToolsSection: some View {
        Section("Agent Tools") {
            Toggle("Enable Agent Tools", isOn: $agentToolsEnabled)

            Toggle("Read File", isOn: $agentReadFileEnabled)
                .disabled(!agentToolsEnabled)

            Toggle("Write File", isOn: $agentWriteFileEnabled)
                .disabled(!agentToolsEnabled)

            Toggle("Require Confirmation", isOn: $agentRequireConfirmation)
                .disabled(!agentToolsEnabled)

            Text("When enabled, the AI will ask for your approval before executing tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.aiProviderId = providerId
        prefs.aiModel = model
        prefs.voiceSTTProvider = sttProvider
        prefs.voiceTTSProvider = ttsProvider
        prefs.elevenLabsVoiceId = elevenLabsVoiceId
        prefs.elevenLabsTTSModelId = elevenLabsTTSModelId
        prefs.agentToolsEnabled = agentToolsEnabled
        prefs.agentReadFileEnabled = agentReadFileEnabled
        prefs.agentWriteFileEnabled = agentWriteFileEnabled
        prefs.agentRequireConfirmation = agentRequireConfirmation
    }
}

// MARK: - Provider Detail View

/// Per-provider configuration: API key, models, test connection.
private struct ProviderDetailView: View {
    let providerId: String
    let store: ConfiguredProviderStore

    @State private var apiKey: String = ""
    @State private var elevenLabsAPIKey: String = ""
    @State private var elevenLabsVoiceId: String = ""
    @State private var elevenLabsTTSModelId: String = ""
    @State private var testResult: String?
    @State private var isTesting: Bool = false

    private var provider: ProviderInfo? {
        ProviderRegistry.shared.provider(for: providerId)
    }

    private var isConfigured: Bool {
        if providerId == "__elevenlabs__" {
            return store.isElevenLabsConfigured
        }
        return store.configuredLLMProviderIds.contains(providerId)
    }

    var body: some View {
        if let provider {
            Form {
                if providerId == "__elevenlabs__" {
                    elevenLabsContent
                } else if isConfigured {
                    configuredProviderContent(provider)
                } else {
                    unconfiguredProviderContent(provider)
                }
            }
            .formStyle(.grouped)
            .onAppear { loadState() }
            .onChange(of: providerId) { _, _ in loadState() }
        } else if providerId == "__elevenlabs__" {
            Form { elevenLabsContent }
                .formStyle(.grouped)
                .onAppear { loadState() }
                .onChange(of: providerId) { _, _ in loadState() }
        } else {
            ContentUnavailableView("Unknown Provider", systemImage: "questionmark.circle")
        }
    }

    // MARK: - Unconfigured Provider

    @ViewBuilder
    private func unconfiguredProviderContent(_ provider: ProviderInfo) -> some View {
        Section {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
        }

        Section("Authentication") {
            switch provider.authStrategy {
            case .apiKey(let envVar):
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                if let envVar {
                    Text("Or set the \(envVar) environment variable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Test & Save") {
                        testAndSaveLLMProvider(provider)
                    }
                    .disabled(apiKey.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("Success") ? .green : .red)
                    }
                }

            case .oauthPKCE:
                Button("Sign in with \(provider.displayName)...") {
                    // OAuth PKCE flow
                }

            case .oauthDeviceCode:
                Button("Connect \(provider.displayName)...") {
                    // Device code flow
                }

            case .none:
                Text("No authentication required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add") {
                    store.refresh()
                }
            }
        }
    }

    // MARK: - Configured Provider

    @ViewBuilder
    private func configuredProviderContent(_ provider: ProviderInfo) -> some View {
        Section {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.title2.weight(.semibold))
                Spacer()
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }

        Section("API Key") {
            HStack {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Button("Update") {
                    if !apiKey.isEmpty {
                        KeychainService.setAPIKey(apiKey, forProviderId: provider.id)
                        testResult = "Key updated"
                    }
                }
                .disabled(apiKey.isEmpty)
                .controlSize(.small)
            }
        }

        Section("Models") {
            ForEach(provider.models) { model in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.name)
                                .font(.body)
                            if model.id == provider.defaultModelId {
                                Text("default")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.yellow.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        HStack(spacing: 8) {
                            Text("\(formatTokens(model.contextWindow)) ctx")
                            Text("\(formatTokens(model.maxTokens)) out")
                            if model.supportsVision {
                                Text("vision")
                            }
                            if model.reasoning {
                                Text("reasoning")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }

        Section("Connection") {
            HStack {
                Button("Test Connection") { testConnection(provider) }
                    .disabled(isTesting)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("Success") ? .green : .red)
                }
            }
        }

        Section {
            Button("Remove Provider", role: .destructive) {
                KeychainService.deleteAPIKey(forProviderId: provider.id)
                OAuthTokenStore.delete(for: provider.id)
                store.refresh()
                apiKey = ""
                testResult = nil
            }
        }
    }

    // MARK: - ElevenLabs

    @ViewBuilder
    private var elevenLabsContent: some View {
        Section {
            HStack(spacing: 8) {
                Text("ElevenLabs")
                    .font(.title2.weight(.semibold))
                Spacer()
                if store.isElevenLabsConfigured {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }

        Section("API Key") {
            SecureField("ElevenLabs API Key", text: $elevenLabsAPIKey)
                .textFieldStyle(.roundedBorder)

            Text("Get your API key from elevenlabs.io")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(store.isElevenLabsConfigured ? "Update" : "Save") {
                Preferences.shared.elevenLabsAPIKey = elevenLabsAPIKey
                store.refresh()
            }
            .disabled(elevenLabsAPIKey.isEmpty)
        }

        if store.isElevenLabsConfigured {
            Section("Voice Settings") {
                TextField("Voice ID", text: $elevenLabsVoiceId)
                    .textFieldStyle(.roundedBorder)

                Picker("TTS Model", selection: $elevenLabsTTSModelId) {
                    Text("Turbo v2.5 (fastest)").tag("eleven_turbo_v2_5")
                    Text("Flash v2.5 (fast)").tag("eleven_flash_v2_5")
                    Text("Multilingual v2 (quality)").tag("eleven_multilingual_v2")
                }

                Button("Save Voice Settings") {
                    let prefs = Preferences.shared
                    prefs.elevenLabsVoiceId = elevenLabsVoiceId
                    prefs.elevenLabsTTSModelId = elevenLabsTTSModelId
                }
            }

            Section {
                Button("Remove ElevenLabs", role: .destructive) {
                    Preferences.shared.elevenLabsAPIKey = ""
                    store.refresh()
                    elevenLabsAPIKey = ""
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadState() {
        apiKey = ""
        testResult = nil
        isTesting = false
        if providerId == "__elevenlabs__" {
            let prefs = Preferences.shared
            elevenLabsAPIKey = prefs.elevenLabsAPIKey
            elevenLabsVoiceId = prefs.elevenLabsVoiceId
            elevenLabsTTSModelId = prefs.elevenLabsTTSModelId
        } else if isConfigured {
            // Show masked key placeholder — user can type new one to update
            apiKey = ""
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    private func testAndSaveLLMProvider(_ provider: ProviderInfo) {
        isTesting = true
        testResult = nil

        KeychainService.setAPIKey(apiKey, forProviderId: provider.id)

        Task {
            do {
                let router = ProviderRouter()
                let testModel = provider.defaultModelId
                let config = ProviderConfig(providerId: provider.id, model: testModel)
                let svc = try router.provider(for: config)
                let messages = [LLMMessage(role: .user, text: "Say 'OK' and nothing else.")]
                let stream = svc.sendMessage(
                    messages: messages, model: testModel,
                    systemPrompt: nil, maxTokens: 50
                )
                var gotDelta = false
                for try await chunk in stream {
                    if case .delta = chunk { gotDelta = true; break }
                }
                await MainActor.run {
                    if gotDelta {
                        testResult = "Success!"
                        store.refresh()
                    } else {
                        testResult = "No response received"
                        KeychainService.deleteAPIKey(forProviderId: provider.id)
                    }
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                    KeychainService.deleteAPIKey(forProviderId: provider.id)
                }
            }
        }
    }

    private func testConnection(_ provider: ProviderInfo) {
        isTesting = true
        testResult = nil

        Task {
            do {
                let router = ProviderRouter()
                let testModel = provider.defaultModelId
                let config = ProviderConfig(providerId: provider.id, model: testModel)
                let svc = try router.provider(for: config)
                let messages = [LLMMessage(role: .user, text: "Say 'OK' and nothing else.")]
                let stream = svc.sendMessage(
                    messages: messages, model: testModel,
                    systemPrompt: nil, maxTokens: 50
                )
                var gotDelta = false
                for try await chunk in stream {
                    if case .delta = chunk { gotDelta = true; break }
                }
                await MainActor.run {
                    testResult = gotDelta ? "Success!" : "No response received"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
