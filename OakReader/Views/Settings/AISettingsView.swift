import SwiftUI
import OakReaderAI

struct AISettingsView: View {
    @State private var providerId: String
    @State private var model: String
    @State private var apiKey: String = ""
    @State private var testResult: String?
    @State private var isTesting: Bool = false
    @State private var agentToolsEnabled: Bool
    @State private var agentReadFileEnabled: Bool
    @State private var agentWriteFileEnabled: Bool
    @State private var agentRequireConfirmation: Bool

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
        _agentToolsEnabled = State(initialValue: prefs.agentToolsEnabled)
        _agentReadFileEnabled = State(initialValue: prefs.agentReadFileEnabled)
        _agentWriteFileEnabled = State(initialValue: prefs.agentWriteFileEnabled)
        _agentRequireConfirmation = State(initialValue: prefs.agentRequireConfirmation)
    }

    var body: some View {
        Form {
            providerSection
            modelInfoSection
            authSection
            agentToolsSection
        }
        .formStyle(.grouped)
        .onAppear { loadAPIKey() }
        .onDisappear { save() }
    }

    // MARK: - Sections

    private var providerSection: some View {
        Section("Provider") {
            Picker("Provider", selection: $providerId) {
                ForEach(ProviderRegistry.shared.allProviders) { p in
                    Text(p.displayName).tag(p.id)
                }
            }
            .onChange(of: providerId) { _, newValue in
                model = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
                loadAPIKey()
            }

            if let provider = selectedProvider {
                Picker("Model", selection: $model) {
                    ForEach(provider.models) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelInfoSection: some View {
        if let info = selectedModelInfo {
            Section("Model Info") {
                LabeledContent("Context Window", value: formatTokens(info.contextWindow))
                LabeledContent("Max Output", value: formatTokens(info.maxTokens))
                LabeledContent("Vision", value: info.supportsVision ? "Yes" : "No")
                LabeledContent("Reasoning", value: info.reasoning ? "Yes" : "No")
            }
        }
    }

    @ViewBuilder
    private var authSection: some View {
        if let provider = selectedProvider {
            Section("Authentication") {
                switch provider.authStrategy {
                case .apiKey(let envVar):
                    SecureField("API Key for \(provider.displayName)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    if let envVar {
                        Text("Or set the \(envVar) environment variable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Test Connection") { testConnection() }
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
                    if OAuthTokenStore.accessToken(for: provider.id) != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Signed in")
                            Spacer()
                            Button("Sign Out") {
                                OAuthTokenStore.delete(for: provider.id)
                                apiKey = ""
                                testResult = nil
                            }
                        }
                    } else {
                        Button("Sign in with \(provider.displayName)...") {
                            // OAuth PKCE flow will be implemented in Phase 3/4
                        }
                    }

                case .oauthDeviceCode:
                    if OAuthTokenStore.accessToken(for: provider.id) != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected")
                            Spacer()
                            Button("Disconnect") {
                                OAuthTokenStore.delete(for: provider.id)
                                apiKey = ""
                                testResult = nil
                            }
                        }
                    } else {
                        Button("Connect \(provider.displayName)...") {
                            // Device code flow will be implemented in Phase 3/4
                        }
                    }

                case .none:
                    Text("No authentication required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

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

    private func loadAPIKey() {
        apiKey = KeychainService.apiKey(forProviderId: providerId) ?? ""
        testResult = nil
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.aiProviderId = providerId
        prefs.aiModel = model
        KeychainService.setAPIKey(apiKey, forProviderId: providerId)
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
