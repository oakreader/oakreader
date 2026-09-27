import SwiftUI
import OakAgent

// MARK: - Skill Management View

/// Settings view showing available skills in a Codex-style catalog.
///
/// The main page stays scannable (large search, category sections, icon-led rows),
/// and tapping a skill swaps this settings pane into an in-place detail/manage page.
struct SkillManagementView: View {
    @State private var catalogSkills: [BackendSkill] = []
    @State private var bundledNames: Set<String> = []
    @State private var installedNames: Set<String> = []
    @State private var disabledNames: Set<String> = []
    @State private var bundledVersions: [String: String] = [:]
    @State private var installedVersions: [String: String] = [:]
    @State private var selectedSkillName: String?
    @State private var searchText = ""
    @State private var filter: SkillListFilter = .all
    /// Incremented to force re-evaluation of resolved paths after install.
    @State private var refreshToken = 0

    /// Where installing a skill puts it: beside the library, which is where
    /// the core looks for them.
    static var installedDir: URL {
        CatalogDatabase.dataDirectory.appendingPathComponent("skills", isDirectory: true)
    }

    private static let recommendedNames: Set<String> = [
        "summarize",
        "web-import",
        "youtube"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let selectedSkill {
                    SkillDetailView(
                        skill: selectedSkill,
                        isInstalled: installedNames.contains(selectedSkill.name),
                        isDisabled: disabledNames.contains(selectedSkill.name),
                        hasUpdate: hasUpdate(selectedSkill),
                        refreshToken: refreshToken,
                        onBack: { selectedSkillName = nil },
                        onInstall: { installSkill(selectedSkill) },
                        onUninstall: { uninstallSkill(selectedSkill) },
                        onUpdate: { installSkill(selectedSkill) },
                        onToggle: { toggleSkillEnabled(selectedSkill) },
                        onBinInstalled: { refreshToken += 1 }
                    )
                } else {
                    header
                    controls

                    if visibleSections.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleSections) { section in
                            SkillCatalogSection(
                                title: section.title,
                                skills: section.skills,
                                installedNames: installedNames,
                                disabledNames: disabledNames,
                                hasUpdate: hasUpdate,
                                refreshToken: refreshToken,
                                onSelect: { selectedSkillName = $0.name },
                                onInstall: { installSkill($0) },
                                onToggle: { toggleSkillEnabled($0) }
                            )
                        }
                    }

                    openFolderFooter
                }
            }
            .frame(maxWidth: 920)
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reload() }
    }

    private var header: some View {
        Text("Make OakReader work your way")
            .font(OakStyle.Font.styled(size: 22, weight: .regular))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 8)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: OakStyle.Font.iconSmall, weight: .regular))
                    .foregroundStyle(.secondary)

                TextField("Search skills", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(OakStyle.Font.styledBody)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 5, y: 2)

            Menu {
                ForEach(SkillListFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        if filter == option {
                            Label(option.title, systemImage: "checkmark")
                                .accessibilityLabel(Text(option.title))
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(filter.title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(OakStyle.Font.styledBody)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    /// Bottom-of-page action to reveal the installed-skills folder in Finder.
    private var openFolderFooter: some View {
        HStack {
            Spacer()
            Button {
                openSkillsFolder()
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .controlSize(.regular)
            Spacer()
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No skills found")
                .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))
            Text("Try a different search or filter.")
                .font(OakStyle.Font.styledCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private var selectedSkill: BackendSkill? {
        guard let selectedSkillName else { return nil }
        return catalogSkills.first { $0.name == selectedSkillName }
    }

    private var visibleSections: [SkillSectionData] {
        let recommended = filtered(
            catalogSkills.filter { Self.recommendedNames.contains($0.name) && bundledNames.contains($0.name) }
        )
        let system = filtered(
            catalogSkills.filter { bundledNames.contains($0.name) && !Self.recommendedNames.contains($0.name) }
        )
        let personal = filtered(
            catalogSkills.filter { !bundledNames.contains($0.name) }
        )

        return [
            SkillSectionData(title: "Recommended", skills: recommended),
            SkillSectionData(title: "System", skills: system),
            SkillSectionData(title: "Personal", skills: personal)
        ].filter { !$0.skills.isEmpty }
    }

    private func filtered(_ skills: [BackendSkill]) -> [BackendSkill] {
        skills
            .filter { skill in
                switch filter {
                case .all:
                    return true
                case .installed:
                    return installedNames.contains(skill.name)
                case .available:
                    return !installedNames.contains(skill.name)
                case .needsSetup:
                    return installedNames.contains(skill.name) && needsSetup(skill)
                }
            }
            .filter { skill in
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return true }
                return skill.name.localizedCaseInsensitiveContains(query)
                    || Self.displayName(for: skill).localizedCaseInsensitiveContains(query)
                    || skill.description.localizedCaseInsensitiveContains(query)
                    || (skill.authorName?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { Self.displayName(for: $0) < Self.displayName(for: $1) }
    }

    private func needsSetup(_ skill: BackendSkill) -> Bool {
        // The core already resolved each tool's path against this machine.
        let hasMissingBins = !skill.missingBins.isEmpty
        let envs = skill.envs
        let hasMissingRequiredEnv = envs.contains {
            $0.required && KeychainService.skillEnvValue(skill: skill.name, envName: $0.name) == nil
        }
        return hasMissingBins || hasMissingRequiredEnv
    }

    // MARK: - Install / Uninstall

    private func installSkill(_ skill: BackendSkill) {
        let fm = FileManager.default
        let destDir = Self.installedDir.appendingPathComponent(skill.name)

        do {
            try fm.createDirectory(at: Self.installedDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destDir.path) {
                try fm.removeItem(at: destDir)
            }
            try fm.copyItem(at: URL(fileURLWithPath: skill.baseDir), to: destDir)
            Task { await SkillStore.shared.reload() }
            reload()
        } catch {
            // Could show alert
        }
    }

    private func uninstallSkill(_ skill: BackendSkill) {
        let destDir = Self.installedDir.appendingPathComponent(skill.name)
        try? FileManager.default.removeItem(at: destDir)
        Task { await SkillStore.shared.reload() }
        reload()
        if !bundledNames.contains(skill.name) {
            selectedSkillName = nil
        }
    }

    // MARK: - Toggle Enabled

    private func toggleSkillEnabled(_ skill: BackendSkill) {
        let skillDir = Self.installedDir.appendingPathComponent(skill.name)
        let jsonURL = skillDir.appendingPathComponent("skill.json")
        let fm = FileManager.default

        var dict: [String: Any] = [:]
        if let data = fm.contents(atPath: jsonURL.path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = existing
        }

        let currentlyEnabled = (dict["enabled"] as? Bool) ?? true
        dict["enabled"] = !currentlyEnabled

        guard let outData = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        fm.createFile(atPath: jsonURL.path, contents: outData)
        Task { await SkillStore.shared.reload() }
        reload()
    }

    // MARK: - Helpers

    /// Re-read the skills from the core.
    ///
    /// Both directories arrive in one listing, duplicates included, which is
    /// what makes the update check possible: a skill installed from the bundled
    /// catalog appears twice, and comparing the two versions is how this knows
    /// whether a newer one is available.
    private func reload() {
        Task { @MainActor in
            let (skills, _) = await SkillCatalog.list()

            let bundled = skills.filter(\.isBundled)
            bundledNames = Set(bundled.map(\.name))
            bundledVersions = [:]
            for skill in bundled where skill.version != nil {
                bundledVersions[skill.name] = skill.version
            }

            let installed = skills.filter { !$0.isBundled }
            installedVersions = [:]
            for skill in installed where skill.version != nil {
                installedVersions[skill.name] = skill.version
            }

            // A user's own skill that is not in the catalog still belongs in
            // the list — it is theirs, and it is the only way to remove it.
            let extra = installed.filter { !bundledNames.contains($0.name) }
            catalogSkills = (bundled + extra)
                .sorted { Self.displayName(for: $0) < Self.displayName(for: $1) }
            installedNames = Set(installed.map(\.name))
            disabledNames = Set(installed.filter { !$0.enabled }.map(\.name))
        }
    }

    func hasUpdate(_ skill: BackendSkill) -> Bool {
        guard installedNames.contains(skill.name),
              bundledNames.contains(skill.name) else { return false }
        guard let bundledVersion = bundledVersions[skill.name] else { return false }
        guard let installedVersion = installedVersions[skill.name] else { return true }
        return Self.compareVersions(bundledVersion, isGreaterThan: installedVersion)
    }

    private static func compareVersions(_ a: String, isGreaterThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
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

    static func displayName(for skill: BackendSkill) -> String {
        skill.name
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func openSkillsFolder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.installedDir.path) {
            try? fm.createDirectory(at: Self.installedDir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(Self.installedDir)
    }
}

private enum SkillListFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case available
    case needsSetup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .installed: return "Added"
        case .available: return "Available"
        case .needsSetup: return "Needs Setup"
        }
    }
}

private struct SkillSectionData: Identifiable {
    let title: String
    let skills: [BackendSkill]

    var id: String { title }
}

// MARK: - Catalog Section

private struct SkillCatalogSection: View {
    let title: String
    let skills: [BackendSkill]
    let installedNames: Set<String>
    let disabledNames: Set<String>
    let hasUpdate: (BackendSkill) -> Bool
    let refreshToken: Int
    let onSelect: (BackendSkill) -> Void
    let onInstall: (BackendSkill) -> Void
    let onToggle: (BackendSkill) -> Void

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 30, alignment: .top),
        GridItem(.flexible(minimum: 0), spacing: 30, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(OakStyle.Font.styled(size: OakStyle.Font.body + 2, weight: .regular))
                    .foregroundStyle(OakStyle.Colors.textPrimary)

                Divider()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(skills) { skill in
                    SkillCatalogItem(
                        skill: skill,
                        isInstalled: installedNames.contains(skill.name),
                        isDisabled: disabledNames.contains(skill.name),
                        hasUpdate: hasUpdate(skill),
                        refreshToken: refreshToken,
                        onSelect: { onSelect(skill) },
                        onInstall: { onInstall(skill) },
                        onToggle: { onToggle(skill) }
                    )
                }
            }
        }
    }
}

// MARK: - Skill Catalog Item

private struct SkillCatalogItem: View {
    let skill: BackendSkill
    let isInstalled: Bool
    let isDisabled: Bool
    let hasUpdate: Bool
    let refreshToken: Int
    let onSelect: () -> Void
    let onInstall: () -> Void
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            SkillIconTile(icon: skill.icon, skillName: skill.name, baseDir: skill.baseDir)
                .opacity(isDisabled ? 0.45 : 1.0)

            VStack(alignment: .leading, spacing: 3) {
                Text(SkillManagementView.displayName(for: skill))
                    .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))
                    .foregroundStyle(isDisabled ? OakStyle.Colors.textTertiary : OakStyle.Colors.textPrimary)
                    .lineLimit(1)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(OakStyle.Font.styledCaption)
                        .foregroundStyle(OakStyle.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            statusAction
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? OakStyle.Colors.hoverBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .help(skill.description)
    }

    @ViewBuilder
    private var statusAction: some View {
        if isInstalled && hasUpdate {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 26, height: 26)
                .help("Update available")
        } else if isInstalled {
            HStack(spacing: 6) {
                if hasMissingSetup {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .help("Setup required")
                }

                Toggle("", isOn: Binding(
                    get: { !isDisabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(isDisabled ? "Enable skill" : "Disable skill")
            }
        } else {
            Button {
                onInstall()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(OakStyle.Colors.textPrimary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(OakStyle.Colors.buttonBackground)
                    )
            }
            .buttonStyle(.plain)
            .help("Add skill")
        }
    }

    private var hasMissingSetup: Bool {
        let _ = refreshToken
        if !skill.missingBins.isEmpty { return true }
        return skill.envs.contains {
            $0.required && KeychainService.skillEnvValue(skill: skill.name, envName: $0.name) == nil
        }
    }
}

// MARK: - Liquid Glass Button Style

private struct LiquidGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(configuration.isPressed ? Color.primary.opacity(0.08) : Color.white.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Skill Detail View

private struct SkillDetailView: View {
    let skill: BackendSkill
    let isInstalled: Bool
    let isDisabled: Bool
    let hasUpdate: Bool
    let refreshToken: Int
    let onBack: () -> Void
    let onInstall: () -> Void
    let onUninstall: () -> Void
    let onUpdate: () -> Void
    let onToggle: () -> Void
    let onBinInstalled: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button {
                onBack()
            } label: {
                Label("Skills", systemImage: "chevron.left")
                    .font(OakStyle.Font.styled(size: OakStyle.Font.body + 1, weight: .medium))
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .foregroundStyle(OakStyle.Colors.textPrimary)

            HStack(alignment: .top, spacing: 14) {
                SkillIconTile(icon: skill.icon, skillName: skill.name, baseDir: skill.baseDir)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(SkillManagementView.displayName(for: skill))
                            .font(OakStyle.Font.styled(size: OakStyle.Font.body + 3, weight: .semibold))

                        if isInstalled {
                            Label("Added", systemImage: "checkmark")
                                .font(OakStyle.Font.styledCaption)
                                .foregroundStyle(.green)
                        }
                    }

                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(OakStyle.Font.styledBody)
                            .foregroundStyle(OakStyle.Colors.textSecondary)
                    }

                    if let authorName = skill.authorName {
                        Text("by \(authorName)")
                            .font(OakStyle.Font.styledCaption)
                            .foregroundStyle(OakStyle.Colors.textTertiary)
                    }
                }

                Spacer()

                if isInstalled {
                    HStack(spacing: 8) {
                        Toggle("Enabled", isOn: Binding(
                            get: { !isDisabled },
                            set: { _ in onToggle() }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        if hasUpdate {
                            Button("Update") { onUpdate() }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Remove", role: .destructive) { onUninstall() }
                            .controlSize(.small)
                    }
                } else {
                    Button("Add Skill") { onInstall() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                setupSection
                filesSection
            }
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        let bins = skill.bins
        let envs = skill.envs

        VStack(alignment: .leading, spacing: 10) {
            Text("Setup")
                .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))

            if bins.isEmpty && envs.isEmpty {
                Text("No dependencies or environment variables required.")
                    .font(OakStyle.Font.styledCaption)
                    .foregroundStyle(OakStyle.Colors.textSecondary)
            } else {
                if !bins.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dependencies")
                            .font(OakStyle.Font.styledCaption)
                            .foregroundStyle(OakStyle.Colors.textSecondary)
                        ForEach(bins, id: \.name) { bin in
                            BinRow(bin: bin, refreshToken: refreshToken, onInstalled: onBinInstalled)
                        }
                    }
                }

                if !envs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Environment")
                            .font(OakStyle.Font.styledCaption)
                            .foregroundStyle(OakStyle.Colors.textSecondary)
                        ForEach(envs, id: \.name) { env in
                            EnvRow(skillName: skill.name, env: env)
                        }
                    }
                }
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))

            Text(skill.baseDir)
                .font(.system(size: OakStyle.Font.caption, design: .monospaced))
                .foregroundStyle(OakStyle.Colors.textTertiary)
                .lineLimit(2)

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: skill.baseDir))
            } label: {
                Label("Open Skill Folder", systemImage: "folder")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Skill Icon Tile

private struct SkillIconTile: View {
    let icon: SkillTileIcon?
    let skillName: String
    let baseDir: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tileGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )

            iconContent
        }
        .frame(width: 36, height: 36)
        .shadow(color: tileColor.opacity(0.12), radius: 5, y: 2)
    }

    @ViewBuilder
    private var iconContent: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        case .url(let raw):
            if let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(6)
                    default:
                        fallbackSymbol
                    }
                }
            } else {
                fallbackSymbol
            }
        case .file(let raw):
            if let image = imageFromFile(raw) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                fallbackSymbol
            }
        case .none:
            fallbackSymbol
        }
    }

    private var fallbackSymbol: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
    }

    private func imageFromFile(_ raw: String) -> NSImage? {
        let url: URL
        if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw)
        } else {
            url = URL(fileURLWithPath: baseDir).appendingPathComponent(raw)
        }
        return NSImage(contentsOf: url)
    }

    private var tileGradient: LinearGradient {
        LinearGradient(
            colors: [tileColor, tileColor.opacity(0.76)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var tileColor: Color {
        switch skillName {
        case "summarize": return .blue
        case "translate", "web-import": return .cyan
        case "youtube": return .red
        case "transcription": return .purple
        case "latex": return .indigo
        case "critique": return .green
        case "grill": return .orange
        case "highlight": return .yellow
        case "outline", "extract": return .teal
        case "socratic", "feynman", "explain": return .mint
        default: return .accentColor
        }
    }
}

// MARK: - Binary Row

private struct BinRow: View {
    let bin: BackendSkillBin
    let refreshToken: Int
    let onInstalled: () -> Void

    @State private var isInstalling = false
    @State private var installError: String?

    var body: some View {
        let _ = refreshToken
        // The path comes from the core, which resolved it while loading the
        // skill; the version is probed here because it means running the tool.
        let path = bin.path
        let ver = path.flatMap { ToolResolver.version(at: $0, versionArgs: []) }

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
                try ToolResolver.install(name: bin.name, install: bin.install ?? [:])
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
    let env: BackendSkillEnv

    @State private var value: String = ""
    @State private var isEditing = false
    @State private var hasValue = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hasValue ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(hasValue ? .green : (env.required ? .orange : .secondary.opacity(0.4)))
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(env.name)
                        .font(.system(size: 12, weight: .medium))

                    if !env.required {
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
