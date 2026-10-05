import SwiftUI

/// Settings for Quick Chat: how it is summoned, whether it reaches other
/// apps, and what each skill does when it runs.
///
/// One trigger, no per-skill keys. The panel exists so nothing has to be
/// memorised; a table of shortcuts in front of it would undo that.
struct QuickChatSettingsView: View {
    @State private var trigger: QuickChatTrigger.Kind = QuickChatBindings.trigger
    @State private var globalEnabled: Bool = QuickChatBindings.isGlobalEnabled
    @State private var isTrusted: Bool = QuickChatAccessibility.isTrusted
    @State private var rejected: String?
    @State private var hidden: Set<String> = QuickChatBindings.hiddenSkills
    @State private var shotTrigger: String = QuickChatBindings.screenshotTrigger?.rawValue ?? ""

    var body: some View {
        Form {
            triggerSection
            otherAppsSection
            skillsSection
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .quickChatTriggerRejected)) { note in
            rejected = note.object as? String
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickChatSkillsChanged)) { _ in
            hidden = QuickChatBindings.hiddenSkills
        }
        .onAppear {
            isTrusted = QuickChatAccessibility.isTrusted
            hidden = QuickChatBindings.hiddenSkills
        }
    }

    // MARK: - Trigger

    private var triggerSection: some View {
        Section {
            Picker("Summon with", selection: $trigger) {
                ForEach(QuickChatTrigger.Kind.allCases) { kind in
                    if let detail = kind.detail {
                        Text("\(kind.display)   — \(detail)").tag(kind)
                    } else {
                        Text(kind.display).tag(kind)
                    }
                }
            }
            .onChange(of: trigger) { _, kind in
                rejected = nil
                QuickChatBindings.trigger = kind
            }

            Picker("Screenshot and ask", selection: $shotTrigger) {
                Text("Off").tag("")
                ForEach(QuickChatTrigger.Kind.allCases) { kind in
                    Text(kind.display).tag(kind.rawValue)
                }
            }
            .onChange(of: shotTrigger) { _, raw in
                QuickChatBindings.screenshotTrigger =
                    raw.isEmpty ? nil : QuickChatTrigger.Kind(rawValue: raw)
            }

            if let rejected {
                Label(
                    "\(rejected) is already taken by another app. Pick a different trigger.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemOrange))
            }
        } header: {
            Text("Trigger")
        } footer: {
            Text(
                "Select text and summon the panel, then pick a skill — the panel is the index, "
                + "so there is nothing else to remember. Holding a modifier is the safest trigger: "
                + "a modifier pressed on its own types nothing, so it cannot collide with typing, "
                + "another app's shortcut, or an input method. Hold it for about a third of a "
                + "second; using it as a modifier the usual way never fires it. "
                + "Screenshot and ask frames a region with the usual macOS crosshair and sends "
                + "the picture itself, so you can ask about a chart or a layout, not only text."
            )
        }
    }

    // MARK: - Other apps

    private var otherAppsSection: some View {
        Section {
            Toggle("Work in other apps", isOn: $globalEnabled)
                .onChange(of: globalEnabled) { _, on in
                    QuickChatBindings.isGlobalEnabled = on
                    if on, !QuickChatAccessibility.isTrusted {
                        QuickChatAccessibility.requestPermission()
                        QuickChatAccessibility.waitForGrant { granted in isTrusted = granted }
                    }
                }

            if globalEnabled {
                LabeledContent("Accessibility") {
                    if isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    } else {
                        Button("Open System Settings…") {
                            QuickChatAccessibility.openSettings()
                            QuickChatAccessibility.waitForGrant { granted in isTrusted = granted }
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        } header: {
            Text("Other Apps")
        } footer: {
            Text(
                "Turning this on puts Quick Chat in the menu bar and watches for the trigger "
                + "everywhere, so you can run a skill over text selected in any app. It needs "
                + "Accessibility permission to read the selection and to write a result back. "
                + "macOS grants that per app signature, so a rebuilt development build has to be "
                + "approved again."
            )
        }
    }

    // MARK: - Skills

    private var skillsSection: some View {
        Section {
            ForEach(QuickChatSkill.all) { skill in
                skillRow(skill)
            }
        } header: {
            Text("Skills")
        } footer: {
            Text(
                "These are your skills — the same ones the chat and the oak command see, read "
                + "from skills/<name>/SKILL.md. Edit one there and it changes everywhere. "
                + "Switch one off to keep it out of Quick Chat without uninstalling it; it stays "
                + "available everywhere else. A skill still only appears when it suits the text: "
                + "rewriting needs somewhere editable to write back to, translating needs text "
                + "that is not already your language."
            )
        }
    }

    private func skillRow(_ skill: QuickChatSkill) -> some View {
        HStack(spacing: 12) {
            Image(systemName: skill.icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name)
                Text(conditionText(skill))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Text(destinationText(skill))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Toggle("", isOn: Binding(
                get: { !hidden.contains(skill.id) },
                set: { QuickChatBindings.setVisible($0, for: skill.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("Show \(skill.name) in Quick Chat")
        }
        .padding(.vertical, 2)
        .opacity(hidden.contains(skill.id) ? 0.5 : 1)
    }

    /// Names the `appliesWhen` rule in words, so a greyed row in the panel is
    /// explainable rather than mysterious.
    private func conditionText(_ skill: QuickChatSkill) -> String {
        if skill.requiresForeignSource { return "When the text is not your language" }
        if skill.requiresOwnSource { return "When the text is your language" }
        if skill.requiresWritable { return "When the text can be edited" }
        return "Always available"
    }

    private func destinationText(_ skill: QuickChatSkill) -> String {
        switch skill.disposition {
        case .copy: return "Copy"
        case .replace: return "Replace"
        }
    }
}
