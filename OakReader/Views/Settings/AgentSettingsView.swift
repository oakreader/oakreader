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
                toggleRow(
                    "Enable Agent Tools",
                    "Let the assistant use tools while chatting",
                    isOn: $agentToolsEnabled
                )
                toggleRow(
                    "Read File",
                    "Open files you reference in chat",
                    isOn: $agentReadFileEnabled,
                    disabled: !agentToolsEnabled
                )
                toggleRow(
                    "Write File",
                    "Create and edit files on your Mac",
                    isOn: $agentWriteFileEnabled,
                    disabled: !agentToolsEnabled
                )
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
                toggleRow(
                    "Remember details about me",
                    "Save durable facts and reuse them across chats",
                    isOn: $memoryEnabled
                )

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

    /// A toggle row with a title and a one-line description beneath it.
    private func toggleRow(
        _ title: String,
        _ subtitle: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(disabled)
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
