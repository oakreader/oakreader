import SwiftUI
import AppKit

struct AISettingsView: View {
    // MARK: - State

    @State private var catalog = AIProviderCatalog.shared
    @State private var navigationPath = NavigationPath()
    @State private var showAddProviderSheet = false
    @State private var modelsFile: RPC.ConfigModelsFileResult?

    // Chat LLM
    @State private var chatProviderId: String
    @State private var chatModel: String

    // MARK: - Init

    init() {
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        _chatProviderId = State(initialValue: pid)
        _chatModel = State(initialValue: AIProviderCatalog.shared.resolvedModelId(
            providerId: pid, stored: prefs.aiModel
        ))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                if let error = catalog.backendError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                providersSection
                chatSection
                customModelsSection
            }
            .formStyle(.grouped)
            .navigationTitle("LLM")
            .navigationDestination(for: String.self) { providerId in
                AIProviderConfigView(providerId: providerId)
            }
            .sheet(isPresented: $showAddProviderSheet) {
                AddProviderSheet { selectedId in
                    showAddProviderSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        navigationPath.append(selectedId)
                    }
                }
            }
        }
        .task {
            await catalog.refresh()
            modelsFile = await catalog.modelsFile()
        }
        .onDisappear { save() }
    }

    // MARK: - Providers Section

    /// Each provider is a row that pushes its own configuration page, the way
    /// System Settings lists applications.
    @ViewBuilder
    private var providersSection: some View {
        Section("Providers") {
            ForEach(catalog.configuredProviders) { provider in
                NavigationLink(value: provider.id) {
                    ProviderRow(provider: provider)
                }
            }

            Button {
                showAddProviderSheet = true
            } label: {
                HStack(spacing: ProviderRow.iconGap) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                        .frame(width: ProviderRow.iconSize, height: ProviderRow.iconSize)

                    Text("Add Provider...")
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Custom Models Section

    /// `models.json` — the user's own endpoints, models and model facts. The
    /// file is the same one pi reads, and the sidecar re-reads it whenever
    /// this pane lists providers.
    @ViewBuilder
    private var customModelsSection: some View {
        Section("Custom Models") {
            LabeledContent("models.json") {
                Button("Open") {
                    Task { @MainActor in
                        if let file = await catalog.modelsFile(create: true) {
                            modelsFile = file
                            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                        }
                    }
                }
            }

            Text("""
                Point a provider at any OpenAI-, Anthropic- or Google-compatible endpoint, \
                add models your build does not ship, and correct a model's context window, \
                output limit, vision or reasoning. Saved edits apply the next time this pane opens.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = modelsFile?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Chat Section

    @ViewBuilder
    private var chatSection: some View {
        Section("Chat") {
            if catalog.configuredProviders.isEmpty {
                Text("Add a provider above to select a default LLM.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $chatProviderId) {
                    ForEach(catalog.configuredProviders) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .onChange(of: chatProviderId) { _, newValue in
                    chatModel = catalog.provider(for: newValue)?.defaultModel ?? ""
                }

                if let provider = catalog.provider(for: chatProviderId) {
                    Picker("Model", selection: $chatModel) {
                        ForEach(provider.models) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                }

                if let info = catalog.modelInfo(providerId: chatProviderId, modelId: chatModel) {
                    LabeledContent("Context Window", value: formatTokens(info.contextWindow))
                    LabeledContent("Max Output", value: formatTokens(info.maxTokens))
                    LabeledContent("Vision", value: info.vision ? "Yes" : "No")
                    LabeledContent("Reasoning", value: info.reasoning ? "Yes" : "No")
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

    private func save() {
        let prefs = Preferences.shared
        prefs.aiProviderId = chatProviderId
        prefs.aiModel = chatModel
    }
}

// MARK: - Provider Row

/// One provider in the list, in the shape System Settings uses for its own
/// per-app rows: icon, name, and a second line summarising the setting so the
/// state is readable without opening the page. The chevron comes from the
/// enclosing `NavigationLink`.
private struct ProviderRow: View {
    let provider: BackendProviderSummary

    static let iconSize: CGFloat = 28
    static let iconGap: CGFloat = 10

    var body: some View {
        HStack(spacing: Self.iconGap) {
            ProviderIconView(
                assetName: "provider-\(provider.id)",
                fallbackSymbol: provider.isLocal ? "desktopcomputer" : "cpu",
                size: Self.iconSize
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                Text(provider.statusSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(provider.needsAttention ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Provider Status Wording

extension BackendProviderSummary {
    /// Where this provider's credential comes from, in one phrase. `source` is
    /// the sidecar's own wording — see pi-ai's `resolve.ts` and
    /// `handleListProviders` in backend/src/main.ts.
    var statusLabel: String {
        if isLocal { return localUrl ?? "Local server" }
        switch auth.source {
        case "OAuth": return "Signed in"
        case "stored credential": return "API key"
        case .some(let source) where source.hasPrefix("OAuth"): return "Sign in again"
        case .some(let envVar): return "API key from \(envVar)"
        case nil: return "Not configured"
        }
    }

    /// True when the row should read as a problem rather than a state.
    var needsAttention: Bool {
        if isLocal { return false }
        guard let source = auth.source else { return true }
        return source.hasPrefix("OAuth") && source != "OAuth"
    }

    /// The list row's second line: credential, endpoint, model count.
    var statusSummary: String {
        var parts = [statusLabel]
        if baseUrlOverride?.isEmpty == false { parts.append("custom endpoint") }
        parts.append(models.count == 1 ? "1 model" : "\(models.count) models")
        return parts.joined(separator: " · ")
    }
}
