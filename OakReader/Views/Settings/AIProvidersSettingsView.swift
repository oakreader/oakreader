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

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        HStack(spacing: 0) {
            providerList
                .frame(width: 280)

            Divider()

            configPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Provider List

    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Defaults row (full width)
                defaultsCard

                sectionHeader("LLM Providers")

                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(allLLMProviders) { provider in
                        let configured = store.configuredLLMProviderIds.contains(provider.id)
                        providerCard(
                            id: provider.id,
                            name: provider.displayName,
                            iconAsset: "provider-\(provider.id)",
                            isConfigured: configured
                        )
                    }
                }

                sectionHeader("Voice & Audio")

                LazyVGrid(columns: gridColumns, spacing: 8) {
                    providerCard(
                        id: Self.elevenLabsId,
                        name: "ElevenLabs",
                        iconAsset: "provider-elevenlabs",
                        isConfigured: store.isElevenLabsConfigured
                    )
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Defaults Card

    private var defaultsCard: some View {
        Button {
            selectedProviderId = Self.defaultsId
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Defaults")
                    .font(.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedProviderId == Self.defaultsId ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selectedProviderId == Self.defaultsId ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Provider Card

    private func providerCard(id: String, name: String, iconAsset: String, isConfigured: Bool) -> some View {
        Button {
            selectedProviderId = id
        } label: {
            VStack(spacing: 6) {
                Image(iconAsset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(name)
                    .font(.caption)
                    .foregroundStyle(isConfigured ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isConfigured ? Color.green : Color.secondary.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedProviderId == id ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selectedProviderId == id ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
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
