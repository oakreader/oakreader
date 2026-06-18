import SwiftUI
import OakAI

struct WebSearchSettingsView: View {
    @State private var selectedProviderId: String = Preferences.shared.webSearchProviderId
    @State private var apiKeys: [String: String] = [:]
    @State private var savedStatus: [String: Bool] = [:]

    private let registry = WebSearchProviderRegistry.shared

    var body: some View {
        Form {
            providerSection
            apiKeysSection
        }
        .formStyle(.grouped)
        .onAppear { loadKeys() }
        .onDisappear { saveSelection() }
    }

    // MARK: - Provider Selection

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $selectedProviderId) {
                Text("Auto (first configured)").tag("auto")
                ForEach(registry.allProviders, id: \.id) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }

            activeProviderStatus
        } header: {
            Text("Search Provider")
        } footer: {
            Text("DuckDuckGo is used as a free fallback when no API key is configured.")
        }
    }

    @ViewBuilder
    private var activeProviderStatus: some View {
        let active = registry.activeProvider()
        if !active.requiresAPIKey {
            Label("Using \(active.displayName) (free, no key required)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary, .green)
        } else {
            Label("Using \(active.displayName)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary, .green)
        }
    }

    // MARK: - API Keys

    private var apiKeysSection: some View {
        Section {
            ForEach(registry.keyedProviders, id: \.id) { provider in
                providerKeyRow(provider)
            }
        } header: {
            Text("API Keys")
        } footer: {
            Text("Enter an API key for any provider to enable it. Keys are stored in Keychain.")
        }
    }

    private func providerKeyRow(_ provider: any WebSearchProvider) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                SecureField(provider.placeholder, text: binding(for: provider.id))
                    .textFieldStyle(.roundedBorder)

                if let envVar = provider.envVar {
                    Text("Or set the \(envVar) environment variable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Save") {
                        saveKey(for: provider)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((apiKeys[provider.id] ?? "").isEmpty)

                    if KeychainService.apiKey(forProviderId: provider.id) != nil {
                        Button("Remove", role: .destructive) {
                            removeKey(for: provider)
                        }
                    }

                    if let url = provider.signupURL {
                        Spacer()
                        Link("Get API key", destination: url)
                            .font(.caption)
                    }
                }

                if savedStatus[provider.id] == true {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                WebProviderIconTile(
                    name: provider.displayName,
                    color: Self.providerColor(provider.id)
                )
                Text(provider.displayName)
            }
        }
    }

    private static func providerColor(_ id: String) -> Color {
        switch id {
        case "web-search-brave": return .orange
        case "web-search-tavily": return .blue
        case "web-search-exa": return .purple
        case "web-search-serper": return .green
        default: return .gray
        }
    }

    // MARK: - Key Management

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { apiKeys[id] ?? "" },
            set: { apiKeys[id] = $0; savedStatus[id] = nil }
        )
    }

    private func loadKeys() {
        for provider in registry.keyedProviders {
            if let existing = KeychainService.apiKey(forProviderId: provider.id) {
                apiKeys[provider.id] = existing
            }
        }
    }

    private func saveKey(for provider: any WebSearchProvider) {
        guard let key = apiKeys[provider.id], !key.isEmpty else { return }
        let success = KeychainService.setAPIKey(key, forProviderId: provider.id)
        savedStatus[provider.id] = success
    }

    private func removeKey(for provider: any WebSearchProvider) {
        KeychainService.deleteAPIKey(forProviderId: provider.id)
        apiKeys[provider.id] = ""
        savedStatus[provider.id] = nil
    }

    private func saveSelection() {
        Preferences.shared.webSearchProviderId = selectedProviderId
    }
}

// MARK: - Provider Icon Tile

/// A small colored monogram tile for brandless web-search providers, giving the
/// API-key rows a leading icon like the AI Providers list.
private struct WebProviderIconTile: View {
    let name: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.gradient)
            .frame(width: 22, height: 22)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
