import SwiftUI
import OakAgent
import OakVoiceAI

// MARK: - Provider Config View (Right Panel)

struct AIProviderConfigView: View {
    let providerId: String
    let store: ConfiguredProviderStore

    var body: some View {
        ProviderDetailView(providerId: providerId, store: store)
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
                    Toggle("", isOn: Binding(
                        get: { Preferences.shared.isModelEnabled(model.id) },
                        set: { enabled in
                            Preferences.shared.setModel(model.id, enabled: enabled)
                            store.refresh()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
                    } else {
                        testResult = "No response received"
                    }
                    store.refresh()
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                    store.refresh()
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
