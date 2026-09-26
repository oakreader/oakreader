import SwiftUI

struct AISettingsView: View {
    // MARK: - State

    @State private var catalog = AIProviderCatalog.shared
    @State private var navigationPath = NavigationPath()
    @State private var showAddProviderSheet = false

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
        .task { await catalog.refresh() }
        .onDisappear { save() }
    }

    // MARK: - Providers Section

    @ViewBuilder
    private var providersSection: some View {
        Section("Providers") {
            ForEach(catalog.configuredProviders) { provider in
                NavigationLink(value: provider.id) {
                    HStack(spacing: 10) {
                        ProviderIconView(
                            assetName: "provider-\(provider.id)",
                            fallbackSymbol: provider.isLocal ? "desktopcomputer" : "cpu"
                        )

                        Text(provider.name)

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    }
                }
            }

            Button {
                showAddProviderSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                        .frame(width: 24, height: 24)

                    Text("Add Provider...")
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
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
