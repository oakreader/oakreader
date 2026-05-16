import SwiftUI
import OakAgent
import OakVoice

struct AIProvidersSettingsView: View {
    /// Sentinel ID for ElevenLabs (not in ProviderRegistry).
    static let elevenLabsId = "__elevenlabs__"
    /// Sentinel ID for Local Models.
    static let localModelsId = "__local_models__"

    let modelStates: SharedModelStates

    @State private var store = ConfiguredProviderStore.shared
    @State private var selectedProviderId: String?

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

                sectionHeader("On-Device")

                listRow(
                    id: Self.localModelsId,
                    iconAsset: nil,
                    sfSymbol: "arrow.down.circle",
                    title: "Local Models",
                    isConfigured: true
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
            HStack(spacing: 10) {
                if let iconAsset {
                    Image(iconAsset)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else if let sfSymbol {
                    Image(systemName: sfSymbol)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isConfigured ? .primary : .secondary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isConfigured ? Color.green : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
        if selectedProviderId == Self.localModelsId {
            LocalModelsSettingsView(modelStates: modelStates)
        } else if let id = selectedProviderId {
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
