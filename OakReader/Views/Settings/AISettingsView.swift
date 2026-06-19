import SwiftUI
import OakAgent

struct AISettingsView: View {
    // MARK: - State

    @State private var store = ConfiguredProviderStore.shared
    @State private var navigationPath = NavigationPath()
    @State private var showAddProviderSheet = false

    // Chat LLM
    @State private var chatProviderId: String
    @State private var chatModel: String

    // Thinking
    @State private var thinkingBudget: Int

    // MARK: - Init

    init() {
        let prefs = Preferences.shared

        // Chat
        let pid = prefs.aiProviderId
        _chatProviderId = State(initialValue: pid)
        let defaultModel = ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
        _chatModel = State(initialValue: prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel)

        // Thinking
        _thinkingBudget = State(initialValue: prefs.thinkingBudget)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                providersSection
                chatSection
                thinkingSection
            }
            .formStyle(.grouped)
            .navigationTitle("LLM")
            .navigationDestination(for: String.self) { providerId in
                AIProviderConfigView(providerId: providerId, store: store)
            }
            .sheet(isPresented: $showAddProviderSheet) {
                AddProviderSheet(store: store) { selectedId in
                    showAddProviderSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        navigationPath.append(selectedId)
                    }
                }
            }
        }
        .onDisappear { save() }
    }

    // MARK: - Providers Section

    @ViewBuilder
    private var providersSection: some View {
        Section("Providers") {
            ForEach(store.configuredLLMProviders) { provider in
                NavigationLink(value: provider.id) {
                    HStack(spacing: 10) {
                        ProviderIconView(
                            assetName: "provider-\(provider.id)",
                            fallbackSymbol: provider.isLocal ? "desktopcomputer" : "cpu"
                        )

                        Text(provider.displayName)

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
            if store.configuredLLMProviders.isEmpty {
                Text("Add a provider above to select a default LLM.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $chatProviderId) {
                    ForEach(store.configuredLLMProviders) { p in
                        Text(p.displayName).tag(p.id)
                    }
                }
                .onChange(of: chatProviderId) { _, newValue in
                    chatModel = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
                }

                if let provider = ProviderRegistry.shared.provider(for: chatProviderId) {
                    Picker("Model", selection: $chatModel) {
                        ForEach(provider.models) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                }

                if let provider = ProviderRegistry.shared.provider(for: chatProviderId),
                   let info = provider.models.first(where: { $0.id == chatModel }) {
                    LabeledContent("Context Window", value: formatTokens(info.contextWindow))
                    LabeledContent("Max Output", value: formatTokens(info.maxTokens))
                    LabeledContent("Vision", value: info.supportsVision ? "Yes" : "No")
                    LabeledContent("Reasoning", value: info.reasoning ? "Yes" : "No")
                }
            }
        }
    }

    // MARK: - Thinking Section

    @ViewBuilder
    private var thinkingSection: some View {
        if let provider = ProviderRegistry.shared.provider(for: chatProviderId),
           let info = provider.models.first(where: { $0.id == chatModel }),
           info.reasoning {
            Section("Extended Thinking") {
                Stepper(
                    "Budget: \(formatTokens(thinkingBudget)) tokens",
                    value: $thinkingBudget,
                    in: 1000...128000,
                    step: 1000
                )

                Text("Token budget for model reasoning. Higher values allow deeper thinking but increase latency and cost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

        // Chat
        prefs.aiProviderId = chatProviderId
        prefs.aiModel = chatModel

        // Thinking
        prefs.thinkingBudget = thinkingBudget
    }
}
