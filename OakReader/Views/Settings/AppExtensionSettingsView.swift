import SwiftUI

struct AppExtensionSettingsView: View {
    @State private var enabledStates: [AppExtension: Bool] = {
        var states: [AppExtension: Bool] = [:]
        for ext in AppExtension.allCases {
            states[ext] = Preferences.shared.isExtensionEnabled(ext)
        }
        return states
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AppExtension.allCases) { ext in
                    extensionRow(ext)
                }
            }
        }
    }

    @ViewBuilder
    private func extensionRow(_ ext: AppExtension) -> some View {
        let isEnabled = enabledStates[ext] ?? ext.enabledByDefault

        HStack(spacing: 10) {
            Image(systemName: ext.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(ext.label)
                    .font(.system(size: 13, weight: .medium))
                Text(ext.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    enabledStates[ext] = newValue
                    Preferences.shared.setExtension(ext, enabled: newValue)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(20)
    }
}
