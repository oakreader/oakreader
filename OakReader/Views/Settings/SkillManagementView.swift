import SwiftUI
import OakAgent

// MARK: - Skill Management View

/// Settings view showing available skills as cards.
///
/// Each card shows install state, and can be expanded to reveal
/// binary dependencies (with install buttons) and environment variable configuration.
struct SkillManagementView: View {
    @State private var catalogSkills: [AgentSkill] = []
    @State private var installedNames: Set<String> = []
    @State private var expandedSkill: String?
    /// Incremented to force re-evaluation of resolved paths after install.
    @State private var refreshToken = 0

    /// Installed skills directory: `~/OakReader/agent/skills/`.
    static let installedDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader/agent/skills", isDirectory: true)
    }()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(catalogSkills) { skill in
                    SkillCard(
                        skill: skill,
                        isInstalled: installedNames.contains(skill.name),
                        isExpanded: expandedSkill == skill.name,
                        refreshToken: refreshToken,
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedSkill = expandedSkill == skill.name ? nil : skill.name
                            }
                        },
                        onInstall: { installSkill(skill) },
                        onUninstall: { uninstallSkill(skill) },
                        onBinInstalled: { refreshToken += 1 }
                    )
                }
            }
            .padding(20)
        }
        .onAppear { reload() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    openSkillsFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
            }
        }
    }

    // MARK: - Install / Uninstall

    private func installSkill(_ skill: AgentSkill) {
        let fm = FileManager.default
        let destDir = Self.installedDir.appendingPathComponent(skill.name)

        do {
            try fm.createDirectory(at: Self.installedDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destDir.path) {
                try fm.removeItem(at: destDir)
            }
            try fm.copyItem(at: URL(fileURLWithPath: skill.baseDir), to: destDir)
            installedNames.insert(skill.name)
        } catch {
            // Could show alert
        }
    }

    private func uninstallSkill(_ skill: AgentSkill) {
        let destDir = Self.installedDir.appendingPathComponent(skill.name)
        try? FileManager.default.removeItem(at: destDir)
        installedNames.remove(skill.name)
    }

    // MARK: - Helpers

    private func reload() {
        var catalogDirs: [URL] = []
        if let bundled = Bundle.main.url(forResource: "skills", withExtension: nil) {
            catalogDirs.append(bundled)
        }
        catalogSkills = SkillLoader.loadSkills(from: catalogDirs).skills

        // Include user skills from installed dir that aren't in catalog
        let installedResult = SkillLoader.loadSkills(from: [Self.installedDir])
        let catalogNames = Set(catalogSkills.map(\.name))
        let extra = installedResult.skills.filter { !catalogNames.contains($0.name) }
        catalogSkills.append(contentsOf: extra)

        installedNames = Self.scanInstalledNames()
    }

    static func scanInstalledNames() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: installedDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var names: Set<String> = []
        for entry in entries {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue { names.insert(entry.lastPathComponent) }
        }
        return names
    }

    private func openSkillsFolder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.installedDir.path) {
            try? fm.createDirectory(at: Self.installedDir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(Self.installedDir)
    }
}

// MARK: - Skill Card

private struct SkillCard: View {
    let skill: AgentSkill
    let isInstalled: Bool
    let isExpanded: Bool
    let refreshToken: Int
    let onToggleExpand: () -> Void
    let onInstall: () -> Void
    let onUninstall: () -> Void
    let onBinInstalled: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
            cardHeader
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpand() }

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                expandedContent
                    .padding(16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isInstalled ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(isInstalled ? .primary : .secondary)
                .frame(width: 32, height: 32)

            // Title + description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 13, weight: .semibold))

                    if let author = skill.author {
                        Text("by \(author.name)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                }
            }

            Spacer()

            // Status badge
            statusBadge

            // Chevron
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(16)
    }

    private var iconName: String {
        if case .symbol(let name) = skill.icon { return name }
        return "hammer"
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isInstalled {
            let bins = skill.requirements?.bins ?? []
            let _ = refreshToken // force re-evaluation
            let missingBins = bins.filter { ToolResolver.resolve(name: $0.name, searchPaths: $0.searchPaths) == nil }

            if !bins.isEmpty && !missingBins.isEmpty {
                Label("\(missingBins.count) missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("Installed")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Dependencies
            if let bins = skill.requirements?.bins, !bins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dependencies")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(bins, id: \.name) { bin in
                        BinRow(bin: bin, refreshToken: refreshToken, onInstalled: onBinInstalled)
                    }
                }
            }

            // Environment variables
            if let envs = skill.requirements?.env, !envs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Environment")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(envs, id: \.name) { env in
                        EnvRow(skillName: skill.name, env: env)
                    }
                }
            }

            // Install / Uninstall button
            HStack {
                Spacer()
                if isInstalled {
                    Button("Uninstall", role: .destructive) { onUninstall() }
                        .controlSize(.small)
                } else {
                    Button("Install") { onInstall() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

// MARK: - Binary Row

private struct BinRow: View {
    let bin: BinRequirement
    let refreshToken: Int
    let onInstalled: () -> Void

    @State private var isInstalling = false
    @State private var installError: String?

    var body: some View {
        let _ = refreshToken
        let path = ToolResolver.resolve(name: bin.name, searchPaths: bin.searchPaths)
        let ver = path.flatMap { ToolResolver.version(at: $0, versionArgs: bin.versionArgs ?? []) }

        HStack(spacing: 8) {
            Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(path != nil ? .green : .orange)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(bin.name)
                        .font(.system(size: 12, weight: .medium))

                    if let ver {
                        Text(ver)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }

                if let desc = bin.description {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if let path {
                    Text(path)
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.tertiary)
                }

                if let error = installError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            // Install button when missing
            if path == nil, bin.install != nil {
                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Install") {
                        installBin()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }

    private func installBin() {
        isInstalling = true
        installError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ToolResolver.install(bin: bin)
                DispatchQueue.main.async {
                    isInstalling = false
                    onInstalled()
                }
            } catch {
                DispatchQueue.main.async {
                    isInstalling = false
                    installError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Env Row

private struct EnvRow: View {
    let skillName: String
    let env: EnvRequirement

    @State private var value: String = ""
    @State private var isEditing = false
    @State private var hasValue = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hasValue ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(hasValue ? .green : (env.isRequired ? .orange : .secondary.opacity(0.4)))
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(env.name)
                        .font(.system(size: 12, weight: .medium))

                    if !env.isRequired {
                        Text("optional")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                if let desc = env.description {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isEditing {
                SecureField("Value", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .controlSize(.small)
                    .onSubmit { save() }

                Button("Save") { save() }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    isEditing = false
                    value = ""
                }
                .controlSize(.mini)
            } else if hasValue {
                Text("••••••••")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.tertiary)

                Button {
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)

                Button {
                    KeychainService.deleteSkillEnvValue(skill: skillName, envName: env.name)
                    hasValue = false
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            } else {
                Button("Set") {
                    isEditing = true
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
        .onAppear {
            hasValue = KeychainService.skillEnvValue(skill: skillName, envName: env.name) != nil
        }
    }

    private func save() {
        guard !value.isEmpty else { return }
        KeychainService.setSkillEnvValue(value, skill: skillName, envName: env.name)
        hasValue = true
        isEditing = false
        value = ""
    }
}
