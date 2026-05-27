import SwiftUI
import OakAgent

struct AddProviderSheet: View {
    let store: ConfiguredProviderStore
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var unconfiguredLLM: [ProviderInfo] {
        store.unconfiguredLLMProviders
    }

    private var showElevenLabs: Bool {
        !store.isElevenLabsConfigured
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Provider")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding()

            Divider()

            List {
                if !unconfiguredLLM.isEmpty {
                    Section("LLM Providers") {
                        ForEach(unconfiguredLLM) { provider in
                            Button {
                                onSelect(provider.id)
                            } label: {
                                providerRow(
                                    iconAsset: "provider-\(provider.id)",
                                    fallbackSymbol: provider.isLocal ? "desktopcomputer" : "cpu",
                                    title: provider.displayName
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if showElevenLabs {
                    Section("Voice & Audio") {
                        Button {
                            onSelect(AISettingsView.elevenLabsId)
                        } label: {
                            providerRow(
                                iconAsset: "provider-elevenlabs",
                                title: "ElevenLabs"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 360, height: 400)
    }

    private func providerRow(iconAsset: String, fallbackSymbol: String = "cpu", title: String) -> some View {
        HStack(spacing: 10) {
            ProviderIconView(assetName: iconAsset, fallbackSymbol: fallbackSymbol)

            Text(title)
                .font(.body)

            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
