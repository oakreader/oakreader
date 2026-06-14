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
    @State private var showUserMemory = false
    @State private var showPrompts = false
    @State private var userFactCount = 0

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

            // MARK: Memory store (the editable facts)
            // HIG (Buttons): a push button that opens another view sits on the row's
            // trailing edge with a trailing ellipsis — modeled on Safari Settings →
            // AutoFill's "Edit…" buttons.
            Section {
                LabeledContent("User memory") {
                    HStack(spacing: 8) {
                        Text(userFactCount == 0 ? "Empty" : "^[\(userFactCount) fact](inflect: true)")
                            .foregroundStyle(.secondary)
                        Button("Manage…") { showUserMemory = true }
                    }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Durable facts the agent knows about you. Edit or remove them any time.")
            }

            // MARK: Background reflection (the feature, distinct from the store)
            Section {
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

                LabeledContent("Reflection prompts") {
                    Button("Customize…") { showPrompts = true }
                }
                .disabled(!memoryEnabled)
            } header: {
                Text("Background Updates")
            } footer: {
                Text("After a conversation settles, the agent quietly consolidates your "
                    + "profile (USER.md) and a per-document continuity brief — off the hot path.")
            }
        }
        .formStyle(.grouped)
        .onAppear { userFactCount = MemoryStore.load(.user).count }
        .onDisappear { save() }
        .sheet(isPresented: $showUserMemory, onDismiss: { userFactCount = MemoryStore.load(.user).count }) {
            MemoryManagerView(scope: .user, title: "User Memory")
        }
        .sheet(isPresented: $showPrompts) {
            MemoryPromptsView(profilePrompt: $profilePrompt, briefPrompt: $briefPrompt)
        }
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

// MARK: - Reflection Prompts Sheet

/// Editing the two background-reflection system prompts. Lives in its own sheet
/// (reached via the "Customize…" button) rather than inline in the settings form,
/// so the multiline editors get room to breathe instead of being crammed into a
/// grouped-form row. Leaving an editor blank falls back to the built-in default.
private struct MemoryPromptsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var profilePrompt: String
    @Binding var briefPrompt: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: OakStyle.Spacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reflection Prompts")
                        .font(.system(size: 15, weight: .semibold))
                    Text("System prompts the background agent uses to consolidate memory. "
                        + "Leave one blank to use the built-in default.")
                        .font(.system(size: 11))
                        .foregroundStyle(OakStyle.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: OakStyle.Spacing.sm)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, OakStyle.Spacing.md)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: OakStyle.Spacing.md) {
                    promptEditor(
                        "Profile consolidation",
                        text: $profilePrompt,
                        placeholder: MemoryReflectionService.defaultProfileSystem
                    )
                    promptEditor(
                        "Document brief",
                        text: $briefPrompt,
                        placeholder: MemoryReflectionService.defaultBriefSystem
                    )
                }
                .padding(OakStyle.Spacing.md)
            }
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func promptEditor(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        let isDefault = text.wrappedValue.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !isDefault {
                    Button("Reset to default") { text.wrappedValue = "" }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                }
            }
            TextEditor(text: Binding(
                get: { isDefault ? placeholder : text.wrappedValue },
                set: { newValue in
                    // Treat "same as default" as no override.
                    text.wrappedValue = (newValue == placeholder) ? "" : newValue
                }
            ))
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 200)
            .foregroundStyle(isDefault ? .secondary : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(OakStyle.Colors.diaHairline, lineWidth: 1)
            )
        }
    }
}
