import SwiftUI
import OakAgent
import OakVoice

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
    @State private var oauthState = OAuthFlowState()

    private var provider: ProviderInfo? {
        ProviderRegistry.shared.provider(for: providerId)
    }

    private var isConfigured: Bool {
        if providerId == "__elevenlabs__" {
            return store.isElevenLabsConfigured
        }
        return store.configuredLLMProviderIds.contains(providerId)
    }

    private var isOAuthProvider: Bool {
        guard let provider else { return false }
        switch provider.authStrategy {
        case .oauthPKCE, .oauthDeviceCode: return true
        default: return false
        }
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
                apiKeyAuthSection(provider: provider, envVar: envVar)

            case .oauthPKCE(let config):
                oauthPKCESection(provider: provider, config: config)

            case .oauthDeviceCode(let config):
                oauthDeviceCodeSection(provider: provider, config: config)

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

    // MARK: - Auth Sections

    @ViewBuilder
    private func apiKeyAuthSection(provider: ProviderInfo, envVar: String?) -> some View {
        SecureField("API Key", text: $apiKey)
            .textFieldStyle(.roundedBorder)

        if let envVar {
            Text("Or set the \(envVar) environment variable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack {
            Button("Test & Save") {
                testAndSaveAPIKey(provider)
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
    }

    @ViewBuilder
    private func oauthPKCESection(provider: ProviderInfo, config: OAuthPKCEConfig) -> some View {
        Button("Sign in with \(provider.displayName)...") {
            startPKCEFlow(provider: provider, config: config)
        }
        .disabled(oauthState.isInProgress)

        oauthProgressView {
            startPKCEFlow(provider: provider, config: config)
        }
    }

    @ViewBuilder
    private func oauthDeviceCodeSection(provider: ProviderInfo, config: DeviceCodeConfig) -> some View {
        if let deviceCode = oauthState.deviceCode {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter this code on GitHub:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(deviceCode.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .textSelection(.enabled)
                Link("Open \(deviceCode.verificationURI)",
                     destination: URL(string: deviceCode.verificationURI)!)
                    .font(.caption)
            }
        } else {
            Button("Connect \(provider.displayName)...") {
                startDeviceCodeFlow(provider: provider, config: config)
            }
            .disabled(oauthState.isInProgress)
        }

        oauthProgressView {
            startDeviceCodeFlow(provider: provider, config: config)
        }
    }

    /// Shared OAuth progress / error / retry / cancel UI.
    @ViewBuilder
    private func oauthProgressView(retryAction: @escaping () -> Void) -> some View {
        if oauthState.isInProgress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for authorization...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { cancelOAuth() }
                    .controlSize(.small)
            }
        }

        if let error = oauthState.error {
            HStack(spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("Retry") { retryAction() }
                    .controlSize(.small)
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

        if !isOAuthProvider {
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
            Button("Reset Provider", role: .destructive) {
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
        cancelOAuth()
        if providerId == "__elevenlabs__" {
            let prefs = Preferences.shared
            elevenLabsAPIKey = prefs.elevenLabsAPIKey
            elevenLabsVoiceId = prefs.elevenLabsVoiceId
            elevenLabsTTSModelId = prefs.elevenLabsTTSModelId
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    // MARK: - Connection Testing

    private func testAndSaveAPIKey(_ provider: ProviderInfo) {
        KeychainService.setAPIKey(apiKey, forProviderId: provider.id)
        testConnection(provider) {
            store.refresh()
        }
    }

    private func testConnection(_ provider: ProviderInfo, onSuccess: (() -> Void)? = nil) {
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
                    if gotDelta { onSuccess?() }
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }

    // MARK: - OAuth Flows

    private func startPKCEFlow(provider: ProviderInfo, config: OAuthPKCEConfig) {
        cancelOAuth()
        oauthState.isInProgress = true

        oauthState.task = Task {
            do {
                let service = OAuthService()
                let tokenSet = try await service.authorizePKCE(config: config)
                OAuthTokenStore.store(tokenSet, for: provider.id)
                await MainActor.run {
                    oauthState.isInProgress = false
                    store.refresh()
                }
            } catch is CancellationError {
                // user cancelled
            } catch {
                await MainActor.run {
                    oauthState.isInProgress = false
                    oauthState.error = error.localizedDescription
                }
            }
        }
    }

    private func startDeviceCodeFlow(provider: ProviderInfo, config: DeviceCodeConfig) {
        cancelOAuth()
        oauthState.isInProgress = true

        oauthState.task = Task {
            do {
                let service = OAuthService()
                let (response, pollTask) = try await service.authorizeDeviceCode(config: config)
                await MainActor.run {
                    oauthState.deviceCode = response
                }
                let tokenSet = try await pollTask.value
                OAuthTokenStore.store(tokenSet, for: provider.id)
                await MainActor.run {
                    oauthState.reset()
                    store.refresh()
                }
            } catch is CancellationError {
                // user cancelled
            } catch {
                await MainActor.run {
                    oauthState.isInProgress = false
                    oauthState.deviceCode = nil
                    oauthState.error = error.localizedDescription
                }
            }
        }
    }

    private func cancelOAuth() {
        oauthState.task?.cancel()
        oauthState.reset()
    }
}

// MARK: - OAuth Flow State

/// Groups all OAuth-related state into one struct to avoid scattered @State variables.
private struct OAuthFlowState {
    var isInProgress: Bool = false
    var error: String?
    var task: Task<Void, Never>?
    var deviceCode: DeviceCodeResponse?

    mutating func reset() {
        isInProgress = false
        error = nil
        task = nil
        deviceCode = nil
    }
}
