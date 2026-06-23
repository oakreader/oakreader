import SwiftUI
import OakAgent

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
    @State private var testResult: String?
    @State private var isTesting: Bool = false
    @State private var oauthState = OAuthFlowState()
    @State private var manualURL: String = ""
    @State private var baseURLOverride: String = ""

    // Local providers (Ollama, LM Studio)
    @State private var serverURL: String = ""
    @State private var isDiscovering: Bool = false
    @State private var discoverResult: String?
    @State private var showResetConfirm = false

    private var provider: ProviderInfo? {
        ProviderRegistry.shared.provider(for: providerId)
    }

    private var isConfigured: Bool {
        store.configuredLLMProviderIds.contains(providerId)
    }

    private var isOAuthProvider: Bool {
        guard let provider else { return false }
        switch provider.authStrategy {
        case .oauthPKCE, .oauthDeviceCode: return true
        default: return false
        }
    }

    private var displayTitle: String {
        provider?.displayName ?? "Provider"
    }

    var body: some View {
        if let provider {
            Form {
                if isConfigured {
                    configuredProviderContent(provider)
                } else {
                    unconfiguredProviderContent(provider)
                }
                if showsSharedActionRow(provider) {
                    sharedActionRow(provider)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(displayTitle)
            .onAppear { loadState() }
            .onChange(of: providerId) { _, _ in loadState() }
        } else {
            ContentUnavailableView("Unknown Provider", systemImage: "questionmark.circle")
        }
    }

    private func showsSharedActionRow(_ provider: ProviderInfo) -> Bool {
        if provider.isLocal { return false }
        if isOAuthProvider { return false }
        if case .apiKey = provider.authStrategy { return true }
        return false
    }

    // MARK: - Unconfigured Provider

    @ViewBuilder
    private func unconfiguredProviderContent(_ provider: ProviderInfo) -> some View {
        if provider.isLocal {
            Section("Server") {
                localServerControls(provider, buttonTitle: "Connect")
            }
        } else {
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

            if !isOAuthProvider {
                endpointSection(provider)
            }
        }
    }

    // MARK: - Endpoint Override (proxy / relay)

    /// Optional custom base URL for a cloud provider, so it can be pointed at a proxy or relay
    /// (e.g. a 中转站) while keeping the same API key, models, and request format.
    @ViewBuilder
    private func endpointSection(_ provider: ProviderInfo) -> some View {
        Section("Endpoint") {
            titledField("Base URL") {
                TextField("Base URL", text: $baseURLOverride, prompt: Text(provider.baseURL.absoluteString))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .labelsHidden()
            }

            Text("Point at a proxy or relay. End with `#` to send the URL exactly as typed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Local Server Controls

    /// Shared URL field + discover button for local OpenAI-compatible providers.
    @ViewBuilder
    private func localServerControls(_ provider: ProviderInfo, buttonTitle: String) -> some View {
        titledField("Server URL") {
            TextField("Server URL", text: $serverURL, prompt: Text("Server URL"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .labelsHidden()
        }

        Text("OpenAI-compatible API base, e.g. http://localhost:11434/v1")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            Button(buttonTitle) { discoverAndSave(provider) }
                .disabled(serverURL.isEmpty || isDiscovering)

            if isDiscovering {
                ProgressView()
                    .controlSize(.small)
            }

            if let result = discoverResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("Found") ? .green : .red)
            }
        }
    }

    private func discoverAndSave(_ provider: ProviderInfo) {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed), base.scheme != nil else {
            discoverResult = "Invalid URL"
            return
        }
        isDiscovering = true
        discoverResult = nil

        Task {
            do {
                let ids = try await LocalModelDiscovery.fetchModelIDs(apiBase: base)
                await MainActor.run {
                    LocalProviderStore.shared.save(id: provider.id, apiBase: trimmed, modelIDs: ids)
                    store.refresh()
                    isDiscovering = false
                    discoverResult = "Found \(ids.count) model\(ids.count == 1 ? "" : "s")"
                }
            } catch {
                await MainActor.run {
                    isDiscovering = false
                    discoverResult = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Auth Sections

    @ViewBuilder
    private func apiKeyAuthSection(provider: ProviderInfo, envVar: String?) -> some View {
        titledField("API Key") {
            SecureField("API Key", text: $apiKey, prompt: Text("API Key"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }

        if let envVar {
            Text("Or set the \(envVar) environment variable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func oauthPKCESection(provider: ProviderInfo, config: OAuthPKCEConfig) -> some View {
        Button("Sign in with \(provider.displayName)...") {
            startPKCEFlow(provider: provider, config: config)
        }
        .disabled(oauthState.isInProgress)

        if oauthState.isInProgress {
            VStack(alignment: .leading, spacing: 4) {
                Text("If the browser didn't redirect back, paste the full URL here:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("http://localhost:\(config.callbackPort)...", text: $manualURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { submitManualURL() }
                    Button("Submit") { submitManualURL() }
                        .controlSize(.small)
                        .disabled(manualURL.isEmpty)
                }
            }
        }

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
            LabeledContent("Status") {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }
        }

        if provider.isLocal {
            Section("Server") {
                localServerControls(provider, buttonTitle: "Refresh Models")
            }
        } else if !isOAuthProvider {
            Section("API Key") {
                SecureField("API Key", text: $apiKey, prompt: Text("API Key"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
        }

        if !provider.isLocal && !isOAuthProvider {
            endpointSection(provider)
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

        Section {
            Button("Reset Provider", role: .destructive) {
                showResetConfirm = true
            }
        }
        .confirmationDialog(
            provider.isLocal ? "Remove this provider?" : "Reset this provider?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(provider.isLocal ? "Remove" : "Reset", role: .destructive) {
                if provider.isLocal {
                    LocalProviderStore.shared.remove(id: provider.id)
                } else {
                    KeychainService.deleteAPIKey(forProviderId: provider.id)
                    OAuthTokenStore.delete(for: provider.id)
                }
                store.refresh()
                apiKey = ""
                testResult = nil
                discoverResult = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(provider.isLocal
                 ? "This removes the local provider configuration."
                 : "Your saved API key and any sign-in for this provider will be permanently deleted. You'll need to re-enter them to use it again.")
        }
    }

    // MARK: - Helpers

    private func loadState() {
        apiKey = KeychainService.apiKey(forProviderId: providerId) ?? ""
        testResult = nil
        isTesting = false
        discoverResult = nil
        isDiscovering = false
        cancelOAuth()
        if let provider, provider.isLocal {
            serverURL = LocalProviderStore.shared.apiBase(for: providerId)
        }
        baseURLOverride = ProviderEndpointStore.shared.displayedBase(for: providerId)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }


    /// A titled input row: a persistent label on its own line with the field beneath it,
    /// matching the label-above-control layout used elsewhere in Settings.
    @ViewBuilder
    private func titledField(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content()
        }
    }

    // MARK: - Shared Action Row

    @ViewBuilder
    private func sharedActionRow(_ provider: ProviderInfo) -> some View {
        Section {
            HStack {
                Button("Test") { testCredentials(provider) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTestDisabled(provider))

                Button("Save") { saveCredentials(provider) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaveDisabled(provider))

                Button("Reset to Default") { resetEndpoint(provider) }
                    .disabled(isResetDisabled(provider))

                if isTesting {
                    ProgressView().controlSize(.small)
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Success") || result.hasPrefix("Saved") ? .green : .red)
                }
            }
        }
    }

    private func isTestDisabled(_ provider: ProviderInfo) -> Bool {
        if isTesting { return true }
        let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return false }
        return KeychainService.apiKey(forProviderId: provider.id) == nil
    }

    private func isSaveDisabled(_ provider: ProviderInfo) -> Bool {
        if isTesting { return true }
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedKey = KeychainService.apiKey(forProviderId: provider.id) ?? ""
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedBase = ProviderEndpointStore.shared.displayedBase(for: provider.id)
        let keyChanged = typedKey != savedKey
        let baseChanged = typedBase != savedBase
        return !keyChanged && !baseChanged
    }

    /// Enabled whenever the field strays from the factory default OR an override
    /// is persisted — the second clause matters when the override was normalized
    /// away because the typed URL happened to equal the default.
    private func isResetDisabled(_ provider: ProviderInfo) -> Bool {
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultBase = ProviderEndpointStore.shared.defaultBase(for: provider.id)
        if typedBase != defaultBase { return false }
        return !ProviderEndpointStore.shared.hasOverride(provider.id)
    }

    // MARK: - Action Handlers

    /// Dry-run validation: stage the typed Base URL into the registry just long
    /// enough to exercise it, then roll back. Persists nothing and leaves the
    /// field text untouched.
    private func testCredentials(_ provider: ProviderInfo) {
        let previousOverride = ProviderEndpointStore.shared.override(for: provider.id)
        stageEndpointForTest(baseURLOverride, for: provider)

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = trimmedKey.isEmpty ? nil : trimmedKey
        let rollback = { [previousOverride] in
            self.stageEndpointForTest(previousOverride, for: provider)
        }

        testConnection(
            provider,
            credential: credential,
            onSuccess: rollback,
            onFailure: rollback
        )
    }

    private func stageEndpointForTest(_ raw: String, for provider: ProviderInfo) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ProviderEndpointStore.shared.clearOverride(for: provider.id)
        } else {
            ProviderEndpointStore.shared.setOverride(trimmed, for: provider.id)
        }
    }

    private func saveCredentials(_ provider: ProviderInfo) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            let saved = KeychainService.setAPIKey(trimmedKey, forProviderId: provider.id)
            guard saved else {
                testResult = "Failed to save key to Keychain"
                return
            }
        }
        let trimmedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBase.isEmpty {
            ProviderEndpointStore.shared.clearOverride(for: provider.id)
        } else {
            ProviderEndpointStore.shared.setOverride(trimmedBase, for: provider.id)
        }
        store.refresh()
        testResult = "Saved."
    }

    private func resetEndpoint(_ provider: ProviderInfo) {
        ProviderEndpointStore.shared.clearOverride(for: provider.id)
        baseURLOverride = ProviderEndpointStore.shared.defaultBase(for: provider.id)
        testResult = "Using default endpoint"
    }

    // MARK: - Connection Testing

    private func testConnection(_ provider: ProviderInfo, credential: String? = nil, onSuccess: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        isTesting = true
        testResult = nil

        Task {
            do {
                let router = ProviderRouter()
                let testModel = provider.defaultModelId
                let config = ProviderConfig(providerId: provider.id, model: testModel)
                let svc: LLMProviderService
                if let credential {
                    svc = try router.provider(for: config, credential: credential)
                } else {
                    svc = try await router.provider(for: config)
                }
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
                    if gotDelta { onSuccess?() } else { onFailure?() }
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                    onFailure?()
                }
            }
        }
    }

    // MARK: - OAuth Flows

    private func startPKCEFlow(provider: ProviderInfo, config: OAuthPKCEConfig) {
        cancelOAuth()
        oauthState.isInProgress = true
        manualURL = ""

        let (stream, continuation) = AsyncStream<String>.makeStream()
        oauthState.manualCodeContinuation = continuation

        oauthState.task = Task {
            do {
                let service = OAuthService()
                let tokenSet = try await service.authorizePKCE(config: config) {
                    for await value in stream { return value }
                    throw CancellationError()
                }
                let stored = OAuthTokenStore.store(tokenSet, for: provider.id)
                await MainActor.run {
                    oauthState.isInProgress = false
                    oauthState.manualCodeContinuation = nil
                    if stored {
                        store.refresh()
                    } else {
                        oauthState.error = "Failed to save credentials to Keychain"
                    }
                }
            } catch is CancellationError {
                // user cancelled
            } catch {
                await MainActor.run {
                    oauthState.isInProgress = false
                    oauthState.manualCodeContinuation = nil
                    oauthState.error = error.localizedDescription
                }
            }
        }
    }

    private func submitManualURL() {
        guard !manualURL.isEmpty else { return }
        oauthState.manualCodeContinuation?.yield(manualURL)
        oauthState.manualCodeContinuation?.finish()
        oauthState.manualCodeContinuation = nil
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
        manualURL = ""
    }
}

// MARK: - OAuth Flow State

/// Groups all OAuth-related state into one struct to avoid scattered @State variables.
private struct OAuthFlowState {
    var isInProgress: Bool = false
    var error: String?
    var task: Task<Void, Never>?
    var deviceCode: DeviceCodeResponse?
    var manualCodeContinuation: AsyncStream<String>.Continuation?

    mutating func reset() {
        isInProgress = false
        error = nil
        task = nil
        deviceCode = nil
        manualCodeContinuation?.finish()
        manualCodeContinuation = nil
    }
}
