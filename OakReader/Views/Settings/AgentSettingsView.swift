import SwiftUI
import OakAgent

struct AgentSettingsView: View {
    @State private var agentToolsEnabled: Bool
    @State private var agentReadFileEnabled: Bool
    @State private var agentWriteFileEnabled: Bool
    @State private var agentPermissionLevel: AgentPermissionLevel

    init() {
        let prefs = Preferences.shared
        _agentToolsEnabled = State(initialValue: prefs.agentToolsEnabled)
        _agentReadFileEnabled = State(initialValue: prefs.agentReadFileEnabled)
        _agentWriteFileEnabled = State(initialValue: prefs.agentWriteFileEnabled)
        _agentPermissionLevel = State(initialValue: prefs.agentPermissionLevel)
    }

    var body: some View {
        Form {
            Section("Agent Tools") {
                Toggle("Enable Agent Tools", isOn: $agentToolsEnabled)

                Toggle("Read File", isOn: $agentReadFileEnabled)
                    .disabled(!agentToolsEnabled)

                Toggle("Write File", isOn: $agentWriteFileEnabled)
                    .disabled(!agentToolsEnabled)

                Picker("Confirmation", selection: $agentPermissionLevel) {
                    ForEach(AgentPermissionLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .disabled(!agentToolsEnabled)

                Text(agentPermissionLevel.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { save() }
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.agentToolsEnabled = agentToolsEnabled
        prefs.agentReadFileEnabled = agentReadFileEnabled
        prefs.agentWriteFileEnabled = agentWriteFileEnabled
        prefs.agentPermissionLevel = agentPermissionLevel
    }
}
