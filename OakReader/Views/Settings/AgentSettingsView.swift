import SwiftUI
import OakAgent

struct AgentSettingsView: View {
    @State private var agentToolsEnabled: Bool
    @State private var agentReadFileEnabled: Bool
    @State private var agentWriteFileEnabled: Bool
    @State private var agentPermissionLevel: AgentPermissionLevel

    // ChatGPT `bio`-style memory
    @State private var memoryEnabled: Bool
    @State private var showUserMemory = false
    @State private var userFactCount = 0

    init() {
        let prefs = Preferences.shared
        _agentToolsEnabled = State(initialValue: prefs.agentToolsEnabled)
        _agentReadFileEnabled = State(initialValue: prefs.agentReadFileEnabled)
        _agentWriteFileEnabled = State(initialValue: prefs.agentWriteFileEnabled)
        _agentPermissionLevel = State(initialValue: prefs.agentPermissionLevel)
        _memoryEnabled = State(initialValue: prefs.memoryEnabled)
    }

    var body: some View {
        Form {
            // MARK: Agent Tools
            Section {
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
            } header: {
                Text("Agent Tools")
            } footer: {
                // HIG: explanatory text belongs in the section footer, not a fake row.
                Text(agentPermissionLevel.description)
            }

            // MARK: Memory
            // The agent saves durable facts about you into one profile and reuses
            // them in every conversation — like ChatGPT's saved memories.
            Section {
                Toggle("Remember details about me", isOn: $memoryEnabled)

                LabeledContent("Saved memories") {
                    HStack(spacing: 8) {
                        Text(userFactCount == 0 ? "Empty" : "^[\(userFactCount) fact](inflect: true)")
                            .foregroundStyle(.secondary)
                        Button("Manage…") { showUserMemory = true }
                    }
                }
                .disabled(!memoryEnabled)
            } header: {
                Text("Memory")
            } footer: {
                Text("The agent saves durable facts about you as you chat and uses them "
                    + "in future conversations. Edit or remove them any time.")
            }
        }
        .formStyle(.grouped)
        .onAppear { userFactCount = MemoryStore.load().count }
        .onDisappear { save() }
        .sheet(isPresented: $showUserMemory, onDismiss: { userFactCount = MemoryStore.load().count }) {
            MemoryManagerView()
        }
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.agentToolsEnabled = agentToolsEnabled
        prefs.agentReadFileEnabled = agentReadFileEnabled
        prefs.agentWriteFileEnabled = agentWriteFileEnabled
        prefs.agentPermissionLevel = agentPermissionLevel
        prefs.memoryEnabled = memoryEnabled
    }
}
