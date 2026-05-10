import SwiftUI
import OakReaderAI
import VoiceAgentKit

struct AIProvidersSettingsView: View {
    @State private var store = ConfiguredProviderStore.shared
    @State private var showAddProvider = false

    // LLM defaults
    @State private var providerId: String
    @State private var model: String

    // TTS/ASR provider
    @State private var sttProvider: String
    @State private var ttsProvider: String
    @State private var elevenLabsAPIKey: String
    @State private var elevenLabsVoiceId: String
    @State private var elevenLabsTTSModelId: String

    // Agent tools
    @State private var agentToolsEnabled: Bool
    @State private var agentReadFileEnabled: Bool
    @State private var agentWriteFileEnabled: Bool
    @State private var agentRequireConfirmation: Bool

    // Connection test
    @State private var testResult: String?
    @State private var isTesting: Bool = false

    private var selectedProvider: ProviderInfo? {
        ProviderRegistry.shared.provider(for: providerId)
    }

    private var selectedModelInfo: ModelInfo? {
        selectedProvider?.models.first { $0.id == model }
    }

    init() {
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        _providerId = State(initialValue: pid)
        let defaultModel = ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
        _model = State(initialValue: prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel)
        _sttProvider = State(initialValue: prefs.voiceSTTProvider)
        _ttsProvider = State(initialValue: prefs.voiceTTSProvider)
        _elevenLabsAPIKey = State(initialValue: prefs.elevenLabsAPIKey)
        _elevenLabsVoiceId = State(initialValue: prefs.elevenLabsVoiceId)
        _elevenLabsTTSModelId = State(initialValue: prefs.elevenLabsTTSModelId)
        _agentToolsEnabled = State(initialValue: prefs.agentToolsEnabled)
        _agentReadFileEnabled = State(initialValue: prefs.agentReadFileEnabled)
        _agentWriteFileEnabled = State(initialValue: prefs.agentWriteFileEnabled)
        _agentRequireConfirmation = State(initialValue: prefs.agentRequireConfirmation)
    }

    var body: some View {
        Form {
            configuredProvidersSection
            llmSection
            ttsSection
            asrSection
            agentToolsSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddProvider) {
            AddProviderSheet {
                store.refresh()
            }
        }
        .onDisappear { save() }
    }

    // MARK: - Configured Providers

    private var configuredProvidersSection: some View {
        Section("Configured Providers") {
            if store.configuredLLMProviders.isEmpty && !store.isElevenLabsConfigured {
                Text("No providers configured yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(store.configuredLLMProviders) { provider in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(provider.displayName)
                    Text("\(provider.models.count) models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") {
                        removeProvider(provider)
                    }
                    .controlSize(.small)
                }
            }

            if store.isElevenLabsConfigured {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("ElevenLabs")
                    Text("Voice & Audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") {
                        Preferences.shared.elevenLabsAPIKey = ""
                        store.refresh()
                    }
                    .controlSize(.small)
                }
            }

            Button {
                showAddProvider = true
            } label: {
                Label("Add Provider", systemImage: "plus")
            }
        }
    }

    // MARK: - LLM

    private var llmSection: some View {
        Section("LLM") {
            if store.configuredLLMProviders.isEmpty {
                Text("Add a provider above to select a default LLM.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $providerId) {
                    ForEach(store.configuredLLMProviders) { p in
                        Text(p.displayName).tag(p.id)
                    }
                }
                .onChange(of: providerId) { _, newValue in
                    model = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
                    testResult = nil
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

                HStack {
                    Button("Test Connection") { testConnection() }
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

    private func removeProvider(_ provider: ProviderInfo) {
        KeychainService.deleteAPIKey(forProviderId: provider.id)
        OAuthTokenStore.delete(for: provider.id)
        store.refresh()
        // If removed provider was the default, switch to first available
        if providerId == provider.id {
            providerId = store.configuredLLMProviders.first?.id ?? providerId
            model = ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? ""
        }
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.aiProviderId = providerId
        prefs.aiModel = model
        prefs.voiceSTTProvider = sttProvider
        prefs.voiceTTSProvider = ttsProvider
        prefs.elevenLabsAPIKey = elevenLabsAPIKey
        prefs.elevenLabsVoiceId = elevenLabsVoiceId
        prefs.elevenLabsTTSModelId = elevenLabsTTSModelId
        prefs.agentToolsEnabled = agentToolsEnabled
        prefs.agentReadFileEnabled = agentReadFileEnabled
        prefs.agentWriteFileEnabled = agentWriteFileEnabled
        prefs.agentRequireConfirmation = agentRequireConfirmation
    }

    private func testConnection() {
        save()
        isTesting = true
        testResult = nil

        Task {
            do {
                let router = ProviderRouter()
                let config = ProviderConfig(providerId: providerId, model: model)
                let svc = try router.provider(for: config)
                let messages = [LLMMessage(role: .user, text: "Say 'OK' and nothing else.")]
                let stream = svc.sendMessage(
                    messages: messages, model: model,
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
