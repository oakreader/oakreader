import SwiftUI
import OakReaderAI

struct AddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdded: () -> Void

    @State private var selectedProvider: ProviderInfo?
    @State private var apiKey: String = ""
    @State private var elevenLabsAPIKey: String = ""
    @State private var testResult: String?
    @State private var isTesting = false

    private var store: ConfiguredProviderStore { ConfiguredProviderStore.shared }

    private var unconfiguredLLMProviders: [ProviderInfo] {
        store.unconfiguredLLMProviders
    }

    private var showElevenLabs: Bool {
        !store.isElevenLabsConfigured
    }

    var body: some View {
        VStack(spacing: 0) {
            if let provider = selectedProvider {
                providerAuthView(provider)
            } else {
                providerListView
            }
        }
        .frame(width: 420, height: 400)
    }

    // MARK: - Provider List

    private var providerListView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Provider")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !unconfiguredLLMProviders.isEmpty {
                        Text("LLM Providers")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(unconfiguredLLMProviders) { provider in
                            Button {
                                selectedProvider = provider
                                apiKey = ""
                                testResult = nil
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "sparkles")
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.displayName)
                                            .font(.body)
                                        Text("\(provider.models.count) models")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if showElevenLabs {
                        Divider()

                        Text("Voice & Audio")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Button {
                            selectedProvider = nil
                            elevenLabsAPIKey = ""
                            testResult = nil
                            // Use a sentinel to show ElevenLabs auth
                            selectedProvider = elevenLabsSentinel
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform")
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ElevenLabs")
                                        .font(.body)
                                    Text("Cloud TTS & STT")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if unconfiguredLLMProviders.isEmpty && !showElevenLabs {
                        Text("All providers are configured.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                }
                .padding()
            }
        }
    }

    // Sentinel provider for ElevenLabs (not a real LLM provider)
    private var elevenLabsSentinel: ProviderInfo {
        ProviderInfo(
            id: "__elevenlabs__",
            displayName: "ElevenLabs",
            apiFormat: .openaiCompletions,
            baseURL: URL(string: "https://api.elevenlabs.io")!,
            defaultModelId: "",
            models: [],
            authStrategy: .apiKey(envVar: "ELEVEN_LABS_API_KEY")
        )
    }

    // MARK: - Provider Auth

    private func providerAuthView(_ provider: ProviderInfo) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    selectedProvider = nil
                    testResult = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Text(provider.displayName)
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if provider.id == "__elevenlabs__" {
                        elevenLabsAuthForm
                    } else {
                        llmProviderAuthForm(provider)
                    }
                }
                .padding()
            }
        }
    }

    private func llmProviderAuthForm(_ provider: ProviderInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                if OAuthTokenStore.accessToken(for: provider.id) != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Signed in")
                    }
                    Button("Done") {
                        onAdded()
                        dismiss()
                    }
                } else {
                    Button("Sign in with \(provider.displayName)...") {
                        // OAuth PKCE flow
                    }
                }

            case .oauthDeviceCode:
                if OAuthTokenStore.accessToken(for: provider.id) != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected")
                    }
                    Button("Done") {
                        onAdded()
                        dismiss()
                    }
                } else {
                    Button("Connect \(provider.displayName)...") {
                        // Device code flow
                    }
                }

            case .none:
                Text("No authentication required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add") {
                    onAdded()
                    dismiss()
                }
            }
        }
    }

    private var elevenLabsAuthForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("ElevenLabs API Key", text: $elevenLabsAPIKey)
                .textFieldStyle(.roundedBorder)

            Text("Get your API key from elevenlabs.io")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Save") {
                Preferences.shared.elevenLabsAPIKey = elevenLabsAPIKey
                onAdded()
                dismiss()
            }
            .disabled(elevenLabsAPIKey.isEmpty)
        }
    }

    // MARK: - Helpers

    private func testAndSaveLLMProvider(_ provider: ProviderInfo) {
        isTesting = true
        testResult = nil

        // Save key first so the test can use it
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
                        isTesting = false
                        onAdded()
                        dismiss()
                    } else {
                        testResult = "No response received"
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                    // Remove key on failure
                    KeychainService.deleteAPIKey(forProviderId: provider.id)
                }
            }
        }
    }
}
