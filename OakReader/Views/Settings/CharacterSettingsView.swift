import SwiftUI
import OakAgent
import OakVoiceAI
import UniformTypeIdentifiers

struct CharacterSettingsView: View {
    let database: CatalogDatabase

    @State private var characters: [Character] = []
    @State private var selectedCharacter: Character?
    @State private var catalogTemplates: [CharacterTemplate] = []
    @State private var bundledTemplateNames: Set<String> = []
    @State private var installedTemplateNames: Set<String> = []
    @State private var searchText = ""
    @State private var filter: CharacterListFilter = .all
    @State private var errorMessage: String?

    private let service: VoiceCharacterService

    init(database: CatalogDatabase) {
        self.database = database
        self.service = VoiceCharacterService(database: database)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let selectedCharacter {
                    CharacterDetailView(
                        character: selectedCharacter,
                        onBack: { self.selectedCharacter = nil },
                        onSave: { saveCharacter($0) },
                        onDelete: { deleteCharacter($0) }
                    )
                } else {
                    mainPage
                }
            }
            .frame(maxWidth: 920)
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            reloadCharacterTemplates()
            await loadCharactersAsync()
        }
    }

    // MARK: - Main Page

    @ViewBuilder
    private var mainPage: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }

        header
        controls

        let filteredTemplates = filteredCatalogTemplates
        let filteredChars = filteredCharacters

        if filteredTemplates.isEmpty && filteredChars.isEmpty {
            emptyState
        } else {
            CharacterGridSection(
                templates: filteredTemplates,
                characters: filteredChars,
                installedTemplateNames: installedTemplateNames,
                onAddTemplate: { addTemplate($0) },
                onRemoveTemplate: { removeTemplate($0) },
                onSelectCharacter: { selectedCharacter = $0 },
                onAddNew: { addCharacter() }
            )
        }
    }

    private var header: some View {
        Text("Your AI Study Partners")
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

                TextField("Search characters", text: $searchText)
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
                ForEach(CharacterListFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        if filter == option {
                            Label(option.title, systemImage: "checkmark")
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

            Button {
                addCharacter()
            } label: {
                Label("New Character", systemImage: "plus")
                    .font(OakStyle.Font.styledBody)
            }
            .buttonStyle(LiquidGlassButtonStyle())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No characters found")
                .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))
            Text("Try a different search or filter.")
                .font(OakStyle.Font.styledCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: - Filtering

    private var filteredCatalogTemplates: [CharacterTemplate] {
        catalogTemplates.filter { template in
            switch filter {
            case .all: return true
            case .catalog: return true
            case .custom: return false
            }
        }
        .filter { template in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return template.displayName.localizedCaseInsensitiveContains(query)
                || template.description.localizedCaseInsensitiveContains(query)
                || (template.category?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var filteredCharacters: [Character] {
        characters.filter { character in
            switch filter {
            case .all: return true
            case .catalog: return character.config.sourceTemplateId != nil
            case .custom: return character.config.sourceTemplateId == nil
            }
        }
        .filter { character in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return character.name.localizedCaseInsensitiveContains(query)
                || character.systemPrompt.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Actions

    private func reloadCharacterTemplates() {
        var sources: [(url: URL, bundled: Bool)] = []
        if let bundled = Bundle.main.url(forResource: "character", withExtension: nil) {
            sources.append((bundled, true))
        } else {
            // Development fallback when running from Xcode without bundled resources.
            sources.append((URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("character"), true))
        }
        sources.append((CharacterTemplateLoader.installedDir, false))

        let loaded = CharacterTemplateLoader.loadTemplates(from: sources)
        var byName: [String: CharacterTemplate] = [:]
        for template in loaded {
            // Installed personal templates override bundled templates with the same name.
            if byName[template.name] == nil || !template.isBundled {
                byName[template.name] = template
            }
        }
        catalogTemplates = byName.values.sorted {
            if $0.popularity != $1.popularity { return $0.popularity > $1.popularity }
            return $0.displayName < $1.displayName
        }
        bundledTemplateNames = Set(loaded.filter(\.isBundled).map(\.name))
        refreshInstalledTemplateNames()
    }

    private func refreshInstalledTemplateNames() {
        installedTemplateNames = CharacterTemplateLoader.scanInstalledNames()
            .union(characters.compactMap { $0.config.sourceTemplateId })
    }

    private func loadCharactersAsync() async {
        let svc = service
        do {
            let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Character], Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let chars = try svc.fetchAllCharacters()
                        cont.resume(returning: chars)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            characters = result
            refreshInstalledTemplateNames()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load characters: \(error.localizedDescription)"
        }
    }

    private func reloadCharacters() {
        Task { await loadCharactersAsync() }
    }

    private func addTemplate(_ template: CharacterTemplate) {
        Task {
            do {
                try CharacterTemplateLoader.install(template)

                let alreadyExists = characters.contains { $0.config.sourceTemplateId == template.name }
                if !alreadyExists {
                    let svc = service
                    let language = template.language ?? Preferences.shared.voiceLanguage
                    let existingCharacter = characters.first { $0.name == template.displayName }
                    let character = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Character, Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                var installed: Character
                                if let existingCharacter {
                                    installed = existingCharacter
                                } else {
                                    installed = try svc.createCharacter(
                                        name: template.displayName,
                                        colorHex: template.avatar?.colorHex ?? template.fallbackColorHex,
                                        language: language
                                    )
                                }
                                installed.config.avatar = CharacterTemplateLoader.installedAvatar(for: template)
                                    ?? template.avatar
                                    ?? installed.config.avatar
                                installed.config.systemPrompt = template.systemPrompt
                                installed.config.language = template.language ?? installed.config.language
                                installed.config.llmModel = template.llmModel ?? ""
                                installed.config.sourceTemplateId = template.name
                                try svc.updateCharacter(installed)
                                cont.resume(returning: installed)
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                    selectedCharacter = character
                }

                reloadCharacterTemplates()
                await loadCharactersAsync()
            } catch {
                errorMessage = "Failed to add character: \(error.localizedDescription)"
            }
        }
    }

    private func removeTemplate(_ template: CharacterTemplate) {
        Task {
            do {
                try CharacterTemplateLoader.uninstall(templateName: template.name)
                let svc = service
                let ids = characters.filter { $0.config.sourceTemplateId == template.name }.map(\.id)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            for id in ids {
                                try svc.deleteCharacter(id: id)
                            }
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                if let sel = selectedCharacter, ids.contains(sel.id) {
                    selectedCharacter = nil
                }
                reloadCharacterTemplates()
                await loadCharactersAsync()
            } catch {
                errorMessage = "Failed to remove character: \(error.localizedDescription)"
            }
        }
    }

    private func addCharacter() {
        let colors = ["#5FB236", "#2EA8E5", "#FF8C19", "#A28AE5", "#FF6666", "#E5A02E", "#36B5A0"]
        let color = colors[characters.count % colors.count]
        Task {
            do {
                let svc = service
                let lang = Preferences.shared.voiceLanguage
                let character = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Character, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let c = try svc.createCharacter(name: "New Character", colorHex: color, language: lang)
                            cont.resume(returning: c)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                await loadCharactersAsync()
                selectedCharacter = character
            } catch {
                errorMessage = "Failed to create character: \(error.localizedDescription)"
            }
        }
    }

    private func saveCharacter(_ character: Character) {
        Task {
            do {
                let svc = service
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try svc.updateCharacter(character)
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                await loadCharactersAsync()
                selectedCharacter = nil
            } catch {
                errorMessage = "Failed to save character: \(error.localizedDescription)"
            }
        }
    }

    private func deleteCharacter(_ character: Character) {
        let charId = character.id
        Task {
            do {
                let svc = service
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try svc.deleteCharacter(id: charId)
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                selectedCharacter = nil
                await loadCharactersAsync()
            } catch {
                errorMessage = "Failed to delete character: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Filter

private enum CharacterListFilter: String, CaseIterable, Identifiable {
    case all
    case catalog
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .catalog: return "From Catalog"
        case .custom: return "Custom"
        }
    }
}

// MARK: - Character Grid Section

private struct CharacterGridSection: View {
    let templates: [CharacterTemplate]
    let characters: [Character]
    let installedTemplateNames: Set<String>
    let onAddTemplate: (CharacterTemplate) -> Void
    let onRemoveTemplate: (CharacterTemplate) -> Void
    let onSelectCharacter: (Character) -> Void
    let onAddNew: () -> Void

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 30, alignment: .top),
        GridItem(.flexible(minimum: 0), spacing: 30, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Characters")
                    .font(OakStyle.Font.styled(size: OakStyle.Font.body + 2, weight: .regular))
                    .foregroundStyle(OakStyle.Colors.textPrimary)

                Divider()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                AddCharacterCard(onAdd: onAddNew)

                ForEach(characters) { character in
                    CharacterCardItem(
                        character: character,
                        onSelect: { onSelectCharacter(character) }
                    )
                }

                ForEach(templates.filter { !installedTemplateNames.contains($0.name) }) { template in
                    CharacterCatalogItem(
                        template: template,
                        isInstalled: false,
                        onAdd: { onAddTemplate(template) },
                        onRemove: {}
                    )
                }
            }

            Text("Add a character to make it available in Voice AI. Personal templates can be dropped into ~/OakReader/agent/characters.")
                .font(OakStyle.Font.styledCaption)
                .foregroundStyle(OakStyle.Colors.textSecondary)
        }
    }
}

// MARK: - Catalog Item Card

private struct CharacterCatalogItem: View {
    let template: CharacterTemplate
    let isInstalled: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            CharacterAvatarView(
                avatar: template.avatar ?? CharacterAvatar(colorHex: template.fallbackColorHex),
                initials: template.initials,
                size: 34
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(template.displayName)
                        .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))
                        .foregroundStyle(OakStyle.Colors.textPrimary)
                        .lineLimit(1)

                    if let category = template.category, !category.isEmpty {
                        Text(category)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                }

                if !template.description.isEmpty {
                    Text(template.description)
                        .font(OakStyle.Font.styledCaption)
                        .foregroundStyle(OakStyle.Colors.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            if isInstalled {
                Button("Remove") { onRemove() }
                    .controlSize(.small)
            } else {
                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(OakStyle.Colors.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(OakStyle.Colors.buttonBackground))
                }
                .buttonStyle(.plain)
                .help("Add character")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? OakStyle.Colors.hoverBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

// MARK: - Character Card Item

private struct CharacterCardItem: View {
    let character: Character
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            CharacterAvatarView(avatar: character.avatar, initials: character.initials, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(character.name)
                    .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))
                    .foregroundStyle(OakStyle.Colors.textPrimary)
                    .lineLimit(1)

                if !character.systemPrompt.isEmpty {
                    Text(character.systemPrompt)
                        .font(OakStyle.Font.styledCaption)
                        .foregroundStyle(OakStyle.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OakStyle.Colors.textTertiary)
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
    }
}

// MARK: - Add Character Card

private struct AddCharacterCard: View {
    let onAdd: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(OakStyle.Colors.textTertiary)
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OakStyle.Colors.textTertiary)
            }
            .frame(width: 34, height: 34)

            Text("New Character")
                .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .medium))
                .foregroundStyle(OakStyle.Colors.textSecondary)

            Spacer()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? OakStyle.Colors.hoverBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onAdd() }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Character Avatar View

struct CharacterAvatarView: View {
    let avatar: CharacterAvatar
    let initials: String
    let size: CGFloat

    var body: some View {
        switch avatar.type {
        case .color:
            ZStack {
                Circle()
                    .fill(Color(hex: avatar.colorHex))
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)

        case .icon:
            ZStack {
                Circle()
                    .fill(Color(hex: avatar.colorHex))
                Image(systemName: avatar.icon ?? "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)

        case .image:
            if let path = avatar.imagePath, let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                    Image(systemName: "photo")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
            }
        }
    }
}

// MARK: - Character Detail View

private struct CharacterDetailView: View {
    @State private var name: String
    @State private var config: CharacterConfig
    @State private var showAudioFilePicker = false
    @State private var referenceAudioImportError: String?
    @State private var showDeleteConfirmation = false

    let character: Character
    let onBack: () -> Void
    let onSave: (Character) -> Void
    let onDelete: (Character) -> Void

    init(character: Character, onBack: @escaping () -> Void, onSave: @escaping (Character) -> Void, onDelete: @escaping (Character) -> Void) {
        self.character = character
        self.onBack = onBack
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: character.name)
        _config = State(initialValue: character.config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Back button
            Button {
                onBack()
            } label: {
                Label("Characters", systemImage: "chevron.left")
                    .font(OakStyle.Font.styled(size: OakStyle.Font.body + 1, weight: .medium))
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .foregroundStyle(OakStyle.Colors.textPrimary)

            // Header
            HStack(alignment: .top, spacing: 14) {
                CharacterAvatarView(avatar: character.avatar, initials: character.initials, size: 52)

                VStack(alignment: .leading, spacing: 6) {
                    Text(character.name)
                        .font(OakStyle.Font.styled(size: OakStyle.Font.body + 3, weight: .semibold))

                    HStack(spacing: 8) {
                        let lang = VoiceLanguage(rawValue: character.language)
                        if let lang {
                            Text(lang.displayName)
                                .font(OakStyle.Font.styledCaption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        }

                        if let lastCall = character.lastCall {
                            Text("Last call: \(lastCall.displayTitle)")
                                .font(OakStyle.Font.styledCaption)
                                .foregroundStyle(OakStyle.Colors.textTertiary)
                        }
                    }
                }

                Spacer()
            }

            Divider()

            // Basic section
            sectionHeader("Basic")

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Language", selection: $config.language) {
                ForEach(VoiceLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }

            // Language Model section
            sectionHeader("Language Model")

            let pid = Preferences.shared.aiProviderId
            let models = ProviderRegistry.shared.provider(for: pid)?.models ?? []
            Picker("LLM Model", selection: $config.llmModel) {
                Text("Same as default").tag("")
                ForEach(models.filter { !$0.reasoning }) { m in
                    Text(m.name).tag(m.id)
                }
                let reasoningModels = models.filter { $0.reasoning }
                if !reasoningModels.isEmpty {
                    Section("Reasoning (slower)") {
                        ForEach(reasoningModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            }

            Text("Pick a fast, non-reasoning model for lower latency.")
                .font(OakStyle.Font.styledCaption)
                .foregroundStyle(OakStyle.Colors.textSecondary)

            // Voice section
            sectionHeader("Voice")
            voiceProviderSection

            // Reference Audio section
            sectionHeader("Reference Audio")
            referenceAudioSection

            // System Prompt section
            sectionHeader("System Prompt")

            TextEditor(text: $config.systemPrompt)
                .font(.system(size: 12))
                .frame(minHeight: 100)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button("Save") {
                    var updated = character
                    updated.name = name
                    updated.config = config
                    onSave(updated)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Spacer()

                Button("Delete", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .alert("Delete Character", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete(character)
            }
        } message: {
            Text("Are you sure you want to delete \"\(character.name)\"? This action cannot be undone.")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))
            .padding(.top, 4)
    }

    // MARK: - Voice Provider

    private var voiceProviderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Transcription Provider", selection: transcriptionProviderBinding) {
                Text("Same as Default").tag("")
                ForEach(VoiceProviderType.allCases, id: \.rawValue) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }

            if transcriptionProviderBinding.wrappedValue == VoiceProviderType.onDevice.rawValue {
                Picker("Transcription Model", selection: transcriptionModelBinding) {
                    Text("Same as Default").tag("")
                    ForEach(KnownModels.stt) { option in
                        Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                    }
                }
            } else if transcriptionProviderBinding.wrappedValue == VoiceProviderType.elevenLabs.rawValue {
                Picker("Transcription Model", selection: transcriptionModelBinding) {
                    Text("Same as Default").tag("")
                    Text("Scribe v2 Realtime").tag("scribe_v2_realtime")
                }
            }

            Divider()

            Picker("Speech Provider", selection: ttsProviderBinding) {
                Text("Same as Default").tag("")
                ForEach(VoiceProviderType.allCases, id: \.rawValue) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }

            if ttsProviderBinding.wrappedValue == VoiceProviderType.onDevice.rawValue {
                Picker("Speech Model", selection: $config.ttsVoice.modelId) {
                    Text("Same as Default").tag("")
                    ForEach(KnownModels.tts) { option in
                        Text("\(option.name) (\(option.sizeLabel))").tag(option.repo)
                    }
                }
            } else if ttsProviderBinding.wrappedValue == VoiceProviderType.elevenLabs.rawValue {
                TextField("Voice ID (optional; default if empty)", text: $config.ttsVoice.voiceId)
                    .textFieldStyle(.roundedBorder)

                Picker("Speech Model", selection: $config.ttsVoice.modelId) {
                    Text("Same as Default").tag("")
                    Text("Turbo v2.5 (fastest)").tag("eleven_turbo_v2_5")
                    Text("Flash v2.5 (fast)").tag("eleven_flash_v2_5")
                    Text("Multilingual v2 (quality)").tag("eleven_multilingual_v2")
                }
            }
        }
    }

    // MARK: - Reference Audio

    private var referenceAudioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if config.referenceAudio.path.isEmpty {
                    Text("No reference audio")
                        .foregroundStyle(.secondary)
                } else {
                    Text(URL(fileURLWithPath: config.referenceAudio.path).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Choose...") { showAudioFilePicker = true }
                    .controlSize(.small)
                if !config.referenceAudio.path.isEmpty {
                    Button("Clear") {
                        config.referenceAudio.path = ""
                        referenceAudioImportError = nil
                    }
                    .controlSize(.small)
                }
            }
            .fileImporter(
                isPresented: $showAudioFilePicker,
                allowedContentTypes: [.audio, .wav],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    importReferenceAudio(from: url)
                }
            }

            if let error = referenceAudioImportError {
                Text(error)
                    .font(OakStyle.Font.styledCaption)
                    .foregroundStyle(.red)
            }

            if !config.referenceAudio.path.isEmpty {
                TextField("Reference Text", text: $config.referenceAudio.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
        }
    }

    // MARK: - Bindings

    private var transcriptionProviderBinding: Binding<String> {
        Binding(
            get: { config.transcription?.provider ?? "" },
            set: { value in
                var transcription = config.transcription ?? .init()
                transcription.provider = value
                if value.isEmpty {
                    transcription.modelId = ""
                    transcription.live = nil
                }
                config.transcription = transcription.isEmpty ? nil : transcription
            }
        )
    }

    private var transcriptionModelBinding: Binding<String> {
        Binding(
            get: { config.transcription?.modelId ?? "" },
            set: { value in
                var transcription = config.transcription ?? .init()
                transcription.modelId = value
                config.transcription = transcription.isEmpty ? nil : transcription
            }
        )
    }

    private var ttsProviderBinding: Binding<String> {
        Binding(
            get: { config.ttsVoice.provider },
            set: { value in
                config.ttsVoice.provider = value
                if value.isEmpty {
                    config.ttsVoice.modelId = ""
                    config.ttsVoice.voiceId = ""
                }
            }
        )
    }

    // MARK: - Import Audio

    private func importReferenceAudio(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let fm = FileManager.default
            let directory = CatalogDatabase.characterAssetsDirectory(characterId: character.id)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileName = url.lastPathComponent.isEmpty ? "reference-audio.wav" : url.lastPathComponent
            let destination = directory.appendingPathComponent(fileName)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: url, to: destination)
            config.referenceAudio.path = destination.path
            referenceAudioImportError = nil
        } catch {
            referenceAudioImportError = "Could not import reference audio: \(error.localizedDescription)"
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

// MARK: - Character Template Catalog

private struct CharacterTemplate: Identifiable {
    let name: String
    let displayName: String
    let description: String
    let category: String?
    let popularity: Int
    let language: String?
    let llmModel: String?
    let avatar: CharacterAvatar?
    let previewPrompts: [String]
    let systemPrompt: String
    let sourceDir: URL
    let isBundled: Bool

    var id: String { name }

    var initials: String {
        let words = displayName.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var fallbackColorHex: String {
        let colors = ["#5FB236", "#2EA8E5", "#FF8C19", "#A28AE5", "#FF6666", "#E5A02E", "#36B5A0"]
        let idx = abs(name.hashValue) % colors.count
        return colors[idx]
    }
}

private struct CharacterTemplateManifest: Decodable {
    let name: String
    let displayName: String?
    let description: String?
    let category: String?
    let popularity: Int?
    let language: String?
    let llmModel: String?
    let avatar: CharacterAvatar?
    let previewPrompts: [String]?
    let systemPrompt: String?
}

private enum CharacterTemplateLoader {
    static let installedDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("OakReader/agent/characters", isDirectory: true)

    static func loadTemplates(from sources: [(url: URL, bundled: Bool)]) -> [CharacterTemplate] {
        sources.flatMap { loadTemplates(in: $0.url, bundled: $0.bundled) }
    }

    static func scanInstalledNames() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: installedDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return Set(entries.compactMap { entry in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            guard fm.fileExists(atPath: entry.appendingPathComponent("character.json").path) else { return nil }
            return entry.lastPathComponent
        })
    }

    static func install(_ template: CharacterTemplate) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
        let destDir = installedDir.appendingPathComponent(template.name, isDirectory: true)

        if template.sourceDir.standardizedFileURL == destDir.standardizedFileURL {
            return
        }

        if fm.fileExists(atPath: destDir.path) {
            try fm.removeItem(at: destDir)
        }
        try fm.copyItem(at: template.sourceDir, to: destDir)
    }

    static func uninstall(templateName: String) throws {
        let destDir = installedDir.appendingPathComponent(templateName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.removeItem(at: destDir)
        }
    }

    private static func loadTemplates(in root: URL, bundled: Bool) -> [CharacterTemplate] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        let rootManifest = root.appendingPathComponent("character.json")
        if fm.fileExists(atPath: rootManifest.path), let template = loadTemplate(from: rootManifest, sourceDir: root, bundled: bundled) {
            return [template]
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { entry in
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir), entryIsDir.boolValue else { return nil }
            let manifestURL = entry.appendingPathComponent("character.json")
            guard fm.fileExists(atPath: manifestURL.path) else { return nil }
            return loadTemplate(from: manifestURL, sourceDir: entry, bundled: bundled)
        }
    }

    private static func loadTemplate(from url: URL, sourceDir: URL, bundled: Bool) -> CharacterTemplate? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(CharacterTemplateManifest.self, from: data),
              isValidName(manifest.name) else {
            return nil
        }

        let systemPrompt = manifest.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !systemPrompt.isEmpty else {
            return nil
        }

        return CharacterTemplate(
            name: manifest.name,
            displayName: manifest.displayName ?? displayName(for: manifest.name),
            description: manifest.description ?? "",
            category: manifest.category,
            popularity: manifest.popularity ?? 0,
            language: manifest.language,
            llmModel: manifest.llmModel,
            avatar: resolvedAvatar(manifest.avatar, sourceDir: sourceDir),
            previewPrompts: manifest.previewPrompts ?? [],
            systemPrompt: systemPrompt,
            sourceDir: sourceDir,
            isBundled: bundled
        )
    }

    private static func displayName(for name: String) -> String {
        name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    static func installedAvatar(for template: CharacterTemplate) -> CharacterAvatar? {
        guard var avatar = template.avatar else { return nil }
        guard avatar.type == .image, let imagePath = avatar.imagePath, !imagePath.isEmpty else {
            return avatar
        }

        let fileName = URL(fileURLWithPath: imagePath).lastPathComponent
        let installedPath = installedDir
            .appendingPathComponent(template.name, isDirectory: true)
            .appendingPathComponent(fileName)
            .path
        if FileManager.default.fileExists(atPath: installedPath) {
            avatar.imagePath = installedPath
        }
        return avatar
    }

    private static func resolvedAvatar(_ avatar: CharacterAvatar?, sourceDir: URL) -> CharacterAvatar? {
        guard var avatar else { return nil }
        guard avatar.type == .image, let imagePath = avatar.imagePath, !imagePath.isEmpty else {
            return avatar
        }
        if !(imagePath as NSString).isAbsolutePath {
            avatar.imagePath = sourceDir.appendingPathComponent(imagePath).path
        }
        return avatar
    }

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else {
            return false
        }
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
