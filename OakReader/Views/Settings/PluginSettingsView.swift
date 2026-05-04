import SwiftUI

struct PluginSettingsView: View {
    @State private var enabledStates: [Plugin: Bool] = {
        var states: [Plugin: Bool] = [:]
        for plugin in Plugin.allCases {
            states[plugin] = Preferences.shared.isPluginEnabled(plugin)
        }
        return states
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Plugin.allCases) { plugin in
                    pluginRow(plugin)

                    if plugin != Plugin.allCases.last {
                        Divider()
                            .padding(.horizontal, 20)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: Plugin) -> some View {
        let isEnabled = enabledStates[plugin] ?? plugin.enabledByDefault

        HStack(spacing: 10) {
            Image(systemName: plugin.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.label)
                    .font(.system(size: 13, weight: .medium))
                Text(plugin.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    enabledStates[plugin] = newValue
                    Preferences.shared.setPlugin(plugin, enabled: newValue)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(20)
    }
}
