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
                .frame(width: 180)

            Divider()

            configPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Provider List (Column 2)

    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // Defaults row
                listRow(
                    id: Self.defaultsId,
                    icon: "gearshape",
                    iconColor: .secondary,
                    title: "Defaults",
                    isConfigured: true
                )

                sectionHeader("LLM Providers")

                ForEach(allLLMProviders) { provider in
                    let configured = store.configuredLLMProviderIds.contains(provider.id)
                    listRow(
                        id: provider.id,
                        icon: configured ? "checkmark.circle.fill" : "circle",
                        iconColor: configured ? .green : .secondary,
                        title: provider.displayName,
                        isConfigured: configured
                    )
                }

                sectionHeader("Voice & Audio")

                listRow(
                    id: Self.elevenLabsId,
                    icon: store.isElevenLabsConfigured ? "checkmark.circle.fill" : "circle",
                    iconColor: store.isElevenLabsConfigured ? .green : .secondary,
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

    private func listRow(id: String, icon: String, iconColor: Color, title: String, isConfigured: Bool) -> some View {
        Button {
            selectedProviderId = id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                Text(title)
                    .font(.body)
                    .foregroundStyle(isConfigured ? .primary : .secondary)
                Spacer()
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

    // MARK: - Config Panel (Column 3)

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
