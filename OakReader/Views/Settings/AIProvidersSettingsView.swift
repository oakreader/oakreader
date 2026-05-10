import SwiftUI
import OakReaderAI
import VoiceAgentKit

struct AIProvidersSettingsView: View {
    /// Sentinel ID for the "Defaults" row.
    static let defaultsId = "___defaults___"
    /// Sentinel ID for ElevenLabs (not in ProviderRegistry).
    static let elevenLabsId = "__elevenlabs__"

    @State private var store = ConfiguredProviderStore.shared
    @State private var selectedProviderId: String? = defaultsId

    private var allLLMProviders: [ProviderInfo] {
        ProviderRegistry.shared.allProviders
    }

    var body: some View {
        HStack(spacing: 0) {
            providerList
                .frame(width: 200)

            Divider()

            configPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Provider List

    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // Defaults row
                listRow(
                    id: Self.defaultsId,
                    iconAsset: nil,
                    sfSymbol: "gearshape",
                    title: "Defaults",
                    isConfigured: true
                )

                sectionHeader("LLM Providers")

                ForEach(allLLMProviders) { provider in
                    let configured = store.configuredLLMProviderIds.contains(provider.id)
                    listRow(
                        id: provider.id,
                        iconAsset: "provider-\(provider.id)",
                        sfSymbol: nil,
                        title: provider.displayName,
                        isConfigured: configured
                    )
                }

                sectionHeader("Voice & Audio")

                listRow(
                    id: Self.elevenLabsId,
                    iconAsset: "provider-elevenlabs",
                    sfSymbol: nil,
                    title: "ElevenLabs",
                    isConfigured: store.isElevenLabsConfigured
                )
            }
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func listRow(id: String, iconAsset: String?, sfSymbol: String?, title: String, isConfigured: Bool) -> some View {
        Button {
            selectedProviderId = id
        } label: {
            HStack(spacing: 8) {
                if let iconAsset {
                    Image(iconAsset)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if let sfSymbol {
                    Image(systemName: sfSymbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }

                Text(title)
                    .font(.body)
                    .foregroundStyle(isConfigured ? .primary : .secondary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isConfigured ? Color.green : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedProviderId == id ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    // MARK: - Config Panel

    @ViewBuilder
    private var configPanel: some View {
        if let id = selectedProviderId {
            AIProviderConfigView(providerId: id, store: store)
        } else {
            ContentUnavailableView(
                "Select a Provider",
                systemImage: "sparkles.2",
                description: Text("Choose a provider from the list to configure it.")
            )
        }
    }
}
