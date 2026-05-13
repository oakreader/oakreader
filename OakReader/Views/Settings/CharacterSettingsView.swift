import SwiftUI
import OakAgent
import OakVoiceAI
import UniformTypeIdentifiers

struct CharacterSettingsView: View {
    let database: CatalogDatabase

    @State private var characters: [Character] = []
    @State private var selectedCharacterId: UUID?
    @State private var catalogTemplates: [CharacterTemplate] = []
    @State private var bundledTemplateNames: Set<String> = []
    @State private var installedTemplateNames: Set<String> = []
    @State private var voiceLanguage: String
    @State private var liveTranscription: Bool
    @State private var voiceLLMModel: String
    @State private var errorMessage: String?

    private let service: VoiceCharacterService

    init(database: CatalogDatabase) {
        self.database = database
        self.service = VoiceCharacterService(database: database)
        let prefs = Preferences.shared
        _voiceLanguage = State(initialValue: prefs.voiceLanguage)
        _liveTranscription = State(initialValue: prefs.voiceLiveTranscription)
        _voiceLLMModel = State(initialValue: prefs.voiceLLMModel)
    }

    private var selectedCharacter: Character? {
        characters.first { $0.id == selectedCharacterId }
    }

    var body: some View {
        Form {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            defaultsSection
            characterCatalogSection
            characterListSection

            if let character = selectedCharacter {
                characterDetailSection(character)
            }
        }
        .formStyle(.grouped)
        .task {
            reloadCharacterTemplates()
            await loadCharactersAsync()
        }
        .onDisappear { save() }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        Section("Defaults") {
            Picker("Language", selection: $voiceLanguage) {
                ForEach(VoiceLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }

            let pid = Preferences.shared.aiProviderId
            let models = ProviderRegistry.shared.provider(for: pid)?.models ?? []

            Picker("LLM Model", selection: $voiceLLMModel) {
                Text("Same as AI Chat").tag("")
                ForEach(models.filter { !$0.reasoning }) { model in
                    Text(model.name).tag(model.id)
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
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Live Transcription", isOn: $liveTranscription)
        }
    }

    // MARK: - Character Catalog

    private var characterCatalogSection: some View {
        Section("Popular Characters for Academic PDFs") {
            if catalogTemplates.isEmpty {
                Text("No character templates found.")
                    .foregroundStyle(.secondary)
            }

            ForEach(catalogTemplates) { template in
                HStack(alignment: .top, spacing: 10) {
                    CharacterAvatarView(
                        avatar: template.avatar ?? CharacterAvatar(colorHex: template.fallbackColorHex),
                        initials: template.initials,
                        size: 34
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(template.displayName)
                                .font(.body.weight(.semibold))
                            if let category = template.category, !category.isEmpty {
                                Text(category)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            }
                        }

                        Text(template.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        if !template.previewPrompts.isEmpty {
                            Text(template.previewPrompts.prefix(2).joined(separator: "  ·  "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if installedTemplateNames.contains(template.name) {
                        Button("Remove") {
                            removeTemplate(template)
                        }
                        .controlSize(.small)
                    } else {
                        Button("Add Character") {
                            addTemplate(template)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
            }

            Text("Add a character to make it available in Voice AI. Personal character templates can be dropped into ~/OakReader/agent/characters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Character List

    private var characterListSection: some View {
        Section("Characters") {
            if characters.isEmpty {
                Text("No characters yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(characters) { character in
                Button {
                    selectedCharacterId = selectedCharacterId == character.id ? nil : character.id
                } label: {
                    HStack(spacing: 10) {
                        CharacterAvatarView(avatar: character.avatar, initials: character.initials, size: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(character.name)
                                .font(.body)
                            if !character.systemPrompt.isEmpty {
                                Text(character.systemPrompt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Image(systemName: selectedCharacterId == character.id ? "chevron.down" : "chevron.right")
                            .foregroundStyle(selectedCharacterId == character.id ? .secondary : .tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                addCharacter()
            } label: {
                Label("Add Character", systemImage: "plus")
            }
        }
    }

    // MARK: - Character Detail

    @ViewBuilder
    private func characterDetailSection(_ character: Character) -> some View {
        Section("\(character.name) - Details") {
            CharacterDetailEditor(
                character: character,
                onSave: { updated in
                    saveCharacter(updated)
                },
                onDelete: {
                    deleteCharacter(character)
                }
            )
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
                    let language = template.language ?? voiceLanguage
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
                                installed.config.avatar = template.avatar ?? installed.config.avatar
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
                    selectedCharacterId = character.id
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
                if let selectedCharacterId, ids.contains(selectedCharacterId) {
                    self.selectedCharacterId = nil
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
                let lang = voiceLanguage
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
                selectedCharacterId = character.id
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
                if selectedCharacterId == charId {
                    selectedCharacterId = nil
                }
                await loadCharactersAsync()
            } catch {
                errorMessage = "Failed to delete character: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.voiceLanguage = voiceLanguage
        prefs.voiceLiveTranscription = liveTranscription
        prefs.voiceLLMModel = voiceLLMModel
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

// MARK: - Character Detail Editor

private struct CharacterDetailEditor: View {
    @State private var name: String
    @State private var config: CharacterConfig
    @State private var showAudioFilePicker = false
    @State private var referenceAudioImportError: String?

    let character: Character
    let onSave: (Character) -> Void
    let onDelete: () -> Void

    init(character: Character, onSave: @escaping (Character) -> Void, onDelete: @escaping () -> Void) {
        self.character = character
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: character.name)
        _config = State(initialValue: character.config)
    }

    var body: some View {
        TextField("Name", text: $name)
            .textFieldStyle(.roundedBorder)

        Picker("Language", selection: $config.language) {
            ForEach(VoiceLanguage.allCases) { lang in
                Text(lang.displayName).tag(lang.code)
            }
        }

        let pid = Preferences.shared.aiProviderId
        let models = ProviderRegistry.shared.provider(for: pid)?.models ?? []
        Picker("LLM Model", selection: $config.llmModel) {
            Text("Same as default").tag("")
            ForEach(models) { m in
                Text(m.name).tag(m.id)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("System Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $config.systemPrompt)
                .font(.system(size: 12))
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.2), width: 1)
        }

        voiceProviderSection

        // Reference audio
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
                .font(.caption)
                .foregroundStyle(.red)
        }

        if !config.referenceAudio.path.isEmpty {
            TextField("Reference Text", text: $config.referenceAudio.text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
        }

        HStack {
            Button("Save") {
                var updated = character
                updated.name = name
                updated.config = config
                onSave(updated)
            }
            .keyboardShortcut(.defaultAction)

            Spacer()

            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private var voiceProviderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice Overrides")
                .font(.caption)
                .foregroundStyle(.secondary)

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
            avatar: manifest.avatar,
            previewPrompts: manifest.previewPrompts ?? [],
            systemPrompt: systemPrompt,
            sourceDir: sourceDir,
            isBundled: bundled
        )
    }

    private static func displayName(for name: String) -> String {
        name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
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
