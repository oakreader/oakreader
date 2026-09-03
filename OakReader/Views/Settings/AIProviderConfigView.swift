import SwiftUI
import AppKit

// MARK: - Provider Config View (Right Panel)

struct AIProviderConfigView: View {
    let providerId: String

    var body: some View {
        ProviderDetailView(providerId: providerId)
    }
}

// MARK: - OAuth Flow State

/// Live state of a backend-driven OAuth login (`oauth_login` events).
@Observable
private final class OAuthFlowState {
    var isInProgress = false
    var error: String?
    var authURL: URL?
    var deviceCode: (userCode: String, verificationURI: String)?
    var pendingPrompt: (promptId: String, type: String, message: String)?
    var promptInput = ""
    var requestId: String?
    var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        isInProgress = false
        error = nil
        authURL = nil
        deviceCode = nil
        pendingPrompt = nil
        promptInput = ""
        requestId = nil
    }
}

// MARK: - Provider Detail View

/// Per-provider configuration: API key, endpoint override, models, OAuth,
/// test connection. All state lives in the Node backend; this view reads the
/// `AIProviderCatalog` mirror and proxies mutations.
private struct ProviderDetailView: View {
    let providerId: String

    @State private var catalog = AIProviderCatalog.shared
    @State private var apiKey: String = ""
    @State private var savedKey: String = ""
    @State private var testResult: String?
    @State private var isTesting: Bool = false
    @State private var oauthState = OAuthFlowState()
    @State private var baseURLOverride: String = ""

    // Local providers (Ollama, LM Studio)
    @State private var serverURL: String = ""
    @State private var isDiscovering: Bool = false
    @State private var discoverResult: String?
    @State private var showResetConfirm = false

    private var provider: BackendProviderSummary? {
        catalog.provider(for: providerId)
    }

    private var isConfigured: Bool {
        guard let provider else { return false }
        if provider.isLocal { return !provider.models.isEmpty }
        return provider.auth.configured
    }

    private var isOAuthProvider: Bool {
        provider?.auth.kind == "oauth"
    }

    private var displayTitle: String {
        provider?.name ?? "Provider"
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

    private func showsSharedActionRow(_ provider: BackendProviderSummary) -> Bool {
        !provider.isLocal && !isOAuthProvider
    }

    // MARK: - Unconfigured Provider

    @ViewBuilder
    private func unconfiguredProviderContent(_ provider: BackendProviderSummary) -> some View {
        if provider.isLocal {
            Section("Server") {
                localServerControls(provider, buttonTitle: "Connect")
            }
        } else {
            Section("Authentication") {
                if isOAuthProvider {
                    oauthSection(provider)
                } else {
                    apiKeyAuthSection(provider)
                    if provider.auth.oauthAvailable {
                        oauthSection(provider)
                    }
                }
            }

            if !isOAuthProvider {
                endpointSection(provider)
            }
        }
    }

    // MARK: - Endpoint Override (proxy / relay)

    @ViewBuilder
    private func endpointSection(_ provider: BackendProviderSummary) -> some View {
        Section("Endpoint") {
            titledField("Base URL") {
                TextField("Base URL", text: $baseURLOverride, prompt: Text("Default endpoint"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .labelsHidden()
            }

            Text("Point at a proxy or relay. End with `#` to send the URL exactly as typed. Leave empty for the default endpoint.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Local Server Controls

    @ViewBuilder
    private func localServerControls(_ provider: BackendProviderSummary, buttonTitle: String) -> some View {
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

    private func discoverAndSave(_ provider: BackendProviderSummary) {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed), base.scheme != nil else {
            discoverResult = "Invalid URL"
            return
        }
        isDiscovering = true
        discoverResult = nil

        Task { @MainActor in
            let error = await catalog.setLocalUrl(trimmed, providerId: provider.id)
            isDiscovering = false
            if let error {
                discoverResult = error
            } else {
                let count = catalog.provider(for: provider.id)?.models.count ?? 0
                discoverResult = "Found \(count) model\(count == 1 ? "" : "s")"
            }
        }
    }

    // MARK: - Auth Sections

    @ViewBuilder
    private func apiKeyAuthSection(_ provider: BackendProviderSummary) -> some View {
        titledField("API Key") {
            SecureField("API Key", text: $apiKey, prompt: Text("API Key"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    /// Backend-driven OAuth: the sidecar runs the provider's login flow
    /// (browser PKCE, device code, …) and streams what to show.
    @ViewBuilder
    private func oauthSection(_ provider: BackendProviderSummary) -> some View {
        if let deviceCode = oauthState.deviceCode {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter this code to authorize:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(deviceCode.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .textSelection(.enabled)
                if let url = URL(string: deviceCode.verificationURI) {
                    Link("Open \(deviceCode.verificationURI)", destination: url)
                        .font(.caption)
                }
            }
        } else if !oauthState.isInProgress {
            Button("Sign in with \(provider.name)...") {
                startOAuthLogin(provider)
            }
        }

        if oauthState.isInProgress, let url = oauthState.authURL {
            Link("Open the sign-in page", destination: url)
                .font(.caption)
        }

        if oauthState.isInProgress, let prompt = oauthState.pendingPrompt {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("", text: Bindable(oauthState).promptInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { submitPromptInput() }
                    Button("Submit") { submitPromptInput() }
                        .controlSize(.small)
                        .disabled(oauthState.promptInput.isEmpty)
                }
            }
        }

        if oauthState.isInProgress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for authorization...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { oauthState.reset() }
                    .controlSize(.small)
            }
        }

        if let error = oauthState.error {
            HStack(spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("Retry") { startOAuthLogin(provider) }
                    .controlSize(.small)
            }
        }
    }

    private func startOAuthLogin(_ provider: BackendProviderSummary) {
        oauthState.reset()
        oauthState.isInProgress = true

        oauthState.task = Task { @MainActor in
            do {
                let id = await NodeBackend.shared.makeRequestId(prefix: "oauth")
                oauthState.requestId = id
                let command = BackendCommand(id: id, type: "oauth_login", providerId: provider.id)
                for try await event in await NodeBackend.shared.events(for: command) {
                    switch event.type {
                    case "oauth_notify":
                        switch event.kind {
                        case "auth_url":
                            if let raw = event.url, let url = URL(string: raw) {
                                oauthState.authURL = url
                                NSWorkspace.shared.open(url)
                            }
                        case "device_code":
                            if let code = event.userCode, let uri = event.verificationUri {
                                oauthState.deviceCode = (code, uri)
                                if let url = URL(string: uri) { NSWorkspace.shared.open(url) }
                            }
                        default:
                            break
                        }
                    case "oauth_prompt":
                        if let promptId = event.promptId {
                            oauthState.pendingPrompt = (
                                promptId, event.promptType ?? "text",
                                event.message ?? "Enter the code:"
                            )
                            oauthState.promptInput = ""
                        }
                    case "response":
                        if event.success == true {
                            oauthState.reset()
                            await catalog.refresh()
                        } else {
                            let message = event.message ?? "Sign-in failed"
                            oauthState.reset()
                            oauthState.error = message
                        }
                    default:
                        break
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    let message = error.localizedDescription
                    oauthState.reset()
                    oauthState.error = message
                }
            }
        }
    }

    private func submitPromptInput() {
        guard let requestId = oauthState.requestId,
              let prompt = oauthState.pendingPrompt else { return }
        let value = oauthState.promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        oauthState.pendingPrompt = nil
        oauthState.promptInput = ""
        Task {
            await NodeBackend.shared.send(BackendCommand(
                id: requestId, type: "oauth_prompt_result",
                promptId: prompt.promptId, value: value
            ))
        }
    }

    // MARK: - Configured Provider

    @ViewBuilder
    private func configuredProviderContent(_ provider: BackendProviderSummary) -> some View {
        Section {
            LabeledContent("Status") {
                Label(provider.auth.source ?? "Connected", systemImage: "checkmark.circle.fill")
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
                            if model.id == provider.defaultModel {
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
                            if model.vision {
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
                Task { @MainActor in
                    _ = await catalog.deleteCredential(providerId: provider.id)
                    _ = await catalog.setBaseUrl(nil, providerId: provider.id)
                    apiKey = ""
                    savedKey = ""
                    testResult = nil
                    discoverResult = nil
                }
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
        apiKey = ""
        savedKey = ""
        testResult = nil
        isTesting = false
        discoverResult = nil
        isDiscovering = false
        oauthState.reset()
        baseURLOverride = provider?.baseUrlOverride ?? ""
        if let provider, provider.isLocal {
            serverURL = provider.localUrl ?? ""
        }
        // Prefill the stored key so "Save" enablement can compare against it.
        let pid = providerId
        Task { @MainActor in
            if let key = await AIProviderCatalog.apiKey(for: pid), providerId == pid {
                apiKey = key
                savedKey = key
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    /// A titled input row: a persistent label on its own line with the field beneath it.
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
    private func sharedActionRow(_ provider: BackendProviderSummary) -> some View {
        Section {
            HStack {
                Button("Test") { testCredentials(provider) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTestDisabled(provider))

                Button("Save") { saveCredentials(provider) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaveDisabled(provider))

                Button("Reset to Default") { resetEndpoint(provider) }
                    .disabled(baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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

    private func isTestDisabled(_ provider: BackendProviderSummary) -> Bool {
        if isTesting { return true }
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return !provider.auth.configured
    }

    private func isSaveDisabled(_ provider: BackendProviderSummary) -> Bool {
        if isTesting { return true }
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyChanged = typedKey != savedKey
        let baseChanged = typedBase != (provider.baseUrlOverride ?? "")
        return !keyChanged && !baseChanged
    }

    // MARK: - Actions

    /// Dry-run validation: test the typed key + typed base URL without persisting either.
    private func testCredentials(_ provider: BackendProviderSummary) {
        isTesting = true
        testResult = nil
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            do {
                let request = CompletionRequest(
                    providerId: provider.id,
                    model: provider.defaultModel ?? provider.models.first?.id ?? "",
                    user: "Say 'OK' and nothing else.",
                    maxTokens: 50,
                    overrideCredential: typedKey.isEmpty ? nil : typedKey,
                    overrideBaseUrl: typedBase.isEmpty ? nil : typedBase
                )
                var gotDelta = false
                for try await delta in AIBackend.completions.stream(request) where !delta.isEmpty {
                    gotDelta = true
                    break
                }
                testResult = gotDelta ? "Success!" : "No response received"
            } catch {
                testResult = "Error: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func saveCredentials(_ provider: BackendProviderSummary) {
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            if !typedKey.isEmpty, typedKey != savedKey {
                if let error = await catalog.setAPIKey(typedKey, providerId: provider.id) {
                    testResult = error
                    return
                }
                savedKey = typedKey
            }
            if let error = await catalog.setBaseUrl(
                typedBase.isEmpty ? nil : typedBase, providerId: provider.id
            ) {
                testResult = error
                return
            }
            testResult = "Saved."
        }
    }

    private func resetEndpoint(_ provider: BackendProviderSummary) {
        Task { @MainActor in
            _ = await catalog.setBaseUrl(nil, providerId: provider.id)
            baseURLOverride = ""
            testResult = "Using default endpoint"
        }
    }
}
