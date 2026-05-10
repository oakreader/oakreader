import SwiftUI
import OakReaderAI
import UniformTypeIdentifiers

struct CharacterSettingsView: View {
    @State private var characters: [Character] = []
    @State private var selectedCharacterId: UUID?
    @State private var voiceLanguage: String
    @State private var liveTranscription: Bool
    @State private var voiceLLMModel: String

    init() {
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
            defaultsSection
            characterListSection

            if let character = selectedCharacter {
                characterDetailSection(character)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadCharacters() }
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

    private func loadCharacters() {
        do {
            let db = try CatalogDatabase()
            let svc = VoiceCharacterService(database: db)
            characters = try svc.fetchAllCharacters()
        } catch {
            // Silently handle
        }
    }

    private func addCharacter() {
        let colors = ["#5FB236", "#2EA8E5", "#FF8C19", "#A28AE5", "#FF6666", "#E5A02E", "#36B5A0"]
        let color = colors[characters.count % colors.count]
        do {
            let db = try CatalogDatabase()
            let svc = VoiceCharacterService(database: db)
            let character = try svc.createCharacter(name: "New Character", colorHex: color, language: voiceLanguage)
            loadCharacters()
            selectedCharacterId = character.id
        } catch {
            // Silently handle
        }
    }

    private func saveCharacter(_ character: Character) {
        do {
            let db = try CatalogDatabase()
            let svc = VoiceCharacterService(database: db)
            try svc.updateCharacter(character)
            loadCharacters()
        } catch {
            // Silently handle
        }
    }

    private func deleteCharacter(_ character: Character) {
        do {
            let db = try CatalogDatabase()
            let svc = VoiceCharacterService(database: db)
            try svc.deleteCharacter(id: character.id)
            if selectedCharacterId == character.id {
                selectedCharacterId = nil
            }
            loadCharacters()
        } catch {
            // Silently handle
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

        // TTS Voice
        TextField("TTS Voice ID", text: $config.ttsVoice.voiceId)
            .textFieldStyle(.roundedBorder)

        TextField("TTS Provider", text: $config.ttsVoice.provider)
            .textFieldStyle(.roundedBorder)

        TextField("TTS Model ID", text: $config.ttsVoice.modelId)
            .textFieldStyle(.roundedBorder)

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
