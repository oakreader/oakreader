import SwiftUI
import OakAgent

// MARK: - Plugin Management View

/// Full Codex-style list+detail plugin management view.
struct PluginManagementView: View {
    @State private var service = PluginService.shared
    @State private var selectedPluginName: String?

    var body: some View {
        HStack(spacing: 0) {
            pluginList
                .frame(width: 200)

            Divider()

            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Plugin List

    private var bundledPlugins: [PluginManifest] {
        service.plugins.filter { service.isBundled($0.name) }
    }

    private var userPlugins: [PluginManifest] {
        service.plugins.filter { !service.isBundled($0.name) }
    }

    private var pluginList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Bundled")

                    ForEach(bundledPlugins, id: \.name) { plugin in
                        pluginRow(plugin)
                    }

                    if !userPlugins.isEmpty {
                        sectionHeader("Installed")

                        ForEach(userPlugins, id: \.name) { plugin in
                            pluginRow(plugin)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            listToolbar
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func pluginRow(_ plugin: PluginManifest) -> some View {
        let isEnabled = service.isEnabled(plugin.name)
        let statuses = service.checkTools(for: plugin)
        let hasMissingTools = statuses.contains { $0.path == nil && $0.tool.required }

        return Button {
            selectedPluginName = plugin.name
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconForPlugin(plugin))
                    .font(.system(size: 14))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .frame(width: 20, height: 20)

                Text(plugin.name)
                    .font(.body)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                Spacer()

                if !isEnabled {
                    Image(systemName: "circle")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.4))
                } else if hasMissingTools {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedPluginName == plugin.name ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private var listToolbar: some View {
        HStack(spacing: 8) {
            Button {
                openPluginsFolder()
            } label: {
                Label("Open Folder", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                service.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private var detailPanel: some View {
        if let name = selectedPluginName,
           let plugin = service.plugins.first(where: { $0.name == name }) {
            PluginDetailView(plugin: plugin, service: service)
        } else {
            ContentUnavailableView(
                "Select a Plugin",
                systemImage: "puzzlepiece.extension",
                description: Text("Choose a plugin from the list to view its details.")
            )
        }
    }

    // MARK: - Helpers

    private func iconForPlugin(_ plugin: PluginManifest) -> String {
        switch plugin.name {
        case "web-import": return "globe"
        case "youtube": return "play.rectangle"
        case "transcription": return "waveform"
        case "typesetting": return "doc.richtext"
        case "ai": return "sparkles"
        default: return "puzzlepiece.extension"
        }
    }

    private func openPluginsFolder() {
        let fm = FileManager.default
        let dir = PluginService.userPluginsDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - Plugin Detail View

private struct PluginDetailView: View {
    let plugin: PluginManifest
    let service: PluginService

    @State private var isEnabled: Bool

    init(plugin: PluginManifest, service: PluginService) {
        self.plugin = plugin
        self.service = service
        _isEnabled = State(initialValue: service.isEnabled(plugin.name))
    }

    var body: some View {
        Form {
            headerSection
            toolsSection
            skillsSection
            credentialsSection
            actionsSection
        }
        .formStyle(.grouped)
        .onChange(of: plugin.name) { _, _ in
            isEnabled = service.isEnabled(plugin.name)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plugin.name)
                            .font(.title2.weight(.semibold))
                        Text("v\(plugin.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(plugin.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: isEnabled) { _, newValue in
                        service.setEnabled(plugin.name, newValue)
                    }
            }
        }
    }

    // MARK: - Tools

    @ViewBuilder
    private var toolsSection: some View {
        if !plugin.tools.isEmpty {
            Section("Tools") {
                ForEach(plugin.tools, id: \.name) { tool in
                    toolRow(tool)
                }
            }
        }
    }

    private func toolRow(_ tool: PluginManifest.ToolDeclaration) -> some View {
        let status = service.toolStatuses[tool.name]
        let path = status?.path ?? service.resolve(tool: tool)
        let version = status?.version

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(path != nil ? .green : (tool.required ? .red : .orange))
                    .font(.body)

                Text(tool.name)
                    .font(.body.weight(.medium))

                Text(tool.required ? "required" : "optional")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(tool.required ? Color.red.opacity(0.1) : Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer()

                if let version {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(tool.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let path {
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            } else {
                if tool.install.brew != nil || tool.install.download != nil {
                    Text("Not installed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Not found")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Skills

    @ViewBuilder
    private var skillsSection: some View {
        let skillDirs = pluginSkillDirs()
        let skills = discoverSkills(in: skillDirs)
        if !skills.isEmpty {
            Section("Skills") {
                ForEach(skills, id: \.name) { skill in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                                .font(.body)
                            Text(skill.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Credentials

    @ViewBuilder
    private var credentialsSection: some View {
        if !plugin.credentials.isEmpty {
            Section("Credentials") {
                ForEach(plugin.credentials, id: \.providerId) { cred in
                    credentialRow(cred)
                }
            }
        }
    }

    private func credentialRow(_ cred: PluginManifest.CredentialDeclaration) -> some View {
        let keychainKey = KeychainService.apiKey(forProviderId: cred.providerId)
        let envVal = cred.envVar.flatMap { ProcessInfo.processInfo.environment[$0] }
        let isSet = keychainKey != nil || envVal != nil

        return HStack(spacing: 8) {
            Image(systemName: isSet ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSet ? .green : .secondary.opacity(0.4))
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(cred.displayName)
                    .font(.body)
                if let envVar = cred.envVar {
                    Text("env: \(envVar)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if isSet {
                let source = keychainKey != nil ? "keychain" : "env"
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("not set")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        if !service.isBundled(plugin.name) {
            Section {
                Button("Reveal in Finder") {
                    let dir = PluginService.userPluginsDirectory.appendingPathComponent(plugin.name)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        }
    }

    // MARK: - Skill Discovery Helpers

    private func pluginSkillDirs() -> [URL] {
        var dirs: [URL] = []
        for skillPath in plugin.skills {
            if skillPath.hasPrefix("./") || !skillPath.hasPrefix("/") {
                let pluginDir = PluginService.userPluginsDirectory.appendingPathComponent(plugin.name)
                let relative = skillPath.hasPrefix("./") ? String(skillPath.dropFirst(2)) : skillPath
                dirs.append(pluginDir.appendingPathComponent(relative))
            } else {
                dirs.append(URL(fileURLWithPath: skillPath))
            }
        }
        return dirs
    }

    private func discoverSkills(in dirs: [URL]) -> [AgentSkill] {
        SkillLoader.loadSkills(from: dirs).skills
    }
}
