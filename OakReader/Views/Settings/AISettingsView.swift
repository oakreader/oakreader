import SwiftUI
import OakReaderAI

struct AISettingsView: View {
    @State private var provider: AIProvider
    @State private var model: String
    @State private var apiKey: String = ""
    @State private var testResult: String?
    @State private var isTesting: Bool = false

    private var selectedModelInfo: ModelInfo? {
        provider.models.first { $0.id == model }
    }

    init() {
        let prefs = Preferences.shared
        _provider = State(initialValue: prefs.aiProvider)
        _model = State(initialValue: prefs.aiModel.isEmpty ? prefs.aiProvider.defaultModel : prefs.aiModel)
    }

    var body: some View {
        Form {
            providerSection
            modelInfoSection
            apiKeySection
        }
        .formStyle(.grouped)
        .onAppear { loadAPIKey() }
        .onDisappear { save() }
    }

    // MARK: - Sections

    private var providerSection: some View {
        Section("Provider") {
            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .onChange(of: provider) { _, newValue in
                model = newValue.defaultModel
                loadAPIKey()
            }

            Picker("Model", selection: $model) {
                ForEach(provider.models) { m in
                    Text(m.name).tag(m.id)
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

    private var apiKeySection: some View {
        Section("API Key") {
            SecureField("API Key for \(provider.displayName)", text: $apiKey)
                .textFieldStyle(.roundedBorder)

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
        }
    }

    // MARK: - Helpers

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    private func loadAPIKey() {
        apiKey = KeychainService.apiKey(for: provider) ?? ""
        testResult = nil
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.aiProvider = provider
        prefs.aiModel = model
        KeychainService.setAPIKey(apiKey, for: provider)
    }

    private func testConnection() {
        save()
        isTesting = true
        testResult = nil

        Task {
            do {
                let router = ProviderRouter()
                let config = ProviderConfig(provider: provider, model: model)
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
