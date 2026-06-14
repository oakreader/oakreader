import SwiftUI
import OakAgent

struct AgentSettingsView: View {
    @State private var agentToolsEnabled: Bool
    @State private var agentReadFileEnabled: Bool
    @State private var agentWriteFileEnabled: Bool
    @State private var agentPermissionLevel: AgentPermissionLevel

    // Background memory reflection ("dreaming")
    @State private var memoryEnabled: Bool
    @State private var memoryModel: String
    @State private var memoryFrequency: Int
    @State private var profilePrompt: String
    @State private var briefPrompt: String
    @State private var showPrompts = false
    @State private var showUserMemory = false

    init() {
        let prefs = Preferences.shared
        _agentToolsEnabled = State(initialValue: prefs.agentToolsEnabled)
        _agentReadFileEnabled = State(initialValue: prefs.agentReadFileEnabled)
        _agentWriteFileEnabled = State(initialValue: prefs.agentWriteFileEnabled)
        _agentPermissionLevel = State(initialValue: prefs.agentPermissionLevel)
        _memoryEnabled = State(initialValue: prefs.memoryReflectionEnabled)
        _memoryModel = State(initialValue: prefs.memoryReflectionModel)
        _memoryFrequency = State(initialValue: prefs.memoryReflectionFrequency)
        _profilePrompt = State(initialValue: prefs.memoryProfilePrompt)
        _briefPrompt = State(initialValue: prefs.memoryBriefPrompt)
    }

    /// Models of the current chat provider, offered for the reflection model picker.
    private var availableModels: [ModelInfo] {
        ProviderRegistry.shared.provider(for: Preferences.shared.aiProviderId)?.models ?? []
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

            Section {
                Button {
                    showUserMemory = true
                } label: {
                    Label("Manage user memory…", systemImage: "brain.head.profile")
                }

                Toggle("Update memory in the background", isOn: $memoryEnabled)

                Picker("Model", selection: $memoryModel) {
                    Text("Inherit chat model").tag("")
                    ForEach(availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .disabled(!memoryEnabled)

                Stepper(
                    "Reflect after every \(memoryFrequency) replies",
                    value: $memoryFrequency,
                    in: 2...20
                )
                .disabled(!memoryEnabled)

                DisclosureGroup("Prompts", isExpanded: $showPrompts) {
                    promptEditor(
                        title: "Profile consolidation",
                        text: $profilePrompt,
                        placeholder: MemoryReflectionService.defaultProfileSystem
                    )
                    promptEditor(
                        title: "Document brief",
                        text: $briefPrompt,
                        placeholder: MemoryReflectionService.defaultBriefSystem
                    )
                }
                .disabled(!memoryEnabled)
            } header: {
                Text("Memory")
            } footer: {
                Text("After a conversation settles, the agent quietly consolidates your "
                    + "profile (USER.md) and a per-document continuity brief — off the hot "
                    + "path. Leave a prompt blank to use the built-in default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { save() }
        .sheet(isPresented: $showUserMemory) {
            MemoryManagerView(scope: .user, title: "User Memory")
        }
    }

    @ViewBuilder
    private func promptEditor(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                if !text.wrappedValue.isEmpty {
                    Button("Reset") { text.wrappedValue = "" }
                        .font(.caption)
                        .buttonStyle(.link)
                }
            }
            TextEditor(text: Binding(
                get: { text.wrappedValue.isEmpty ? placeholder : text.wrappedValue },
                set: { newValue in
                    // Treat "same as default" as no override.
                    text.wrappedValue = (newValue == placeholder) ? "" : newValue
                }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 120)
            .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .padding(.vertical, 4)
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.agentToolsEnabled = agentToolsEnabled
        prefs.agentReadFileEnabled = agentReadFileEnabled
        prefs.agentWriteFileEnabled = agentWriteFileEnabled
        prefs.agentPermissionLevel = agentPermissionLevel
        prefs.memoryReflectionEnabled = memoryEnabled
        prefs.memoryReflectionModel = memoryModel
        prefs.memoryReflectionFrequency = memoryFrequency
        prefs.memoryProfilePrompt = profilePrompt
        prefs.memoryBriefPrompt = briefPrompt
    }
}
