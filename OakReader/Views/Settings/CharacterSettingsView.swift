import SwiftUI
import OakReaderAI
import UniformTypeIdentifiers

struct CharacterSettingsView: View {
    @State private var characters: [Character] = []
    @State private var selectedCharacterId: UUID?
    @State private var voiceLanguage: String
    @State private var liveTranscription: Bool
    @State private var voiceLLMModel: String

    private var service: VoiceCharacterService {
        guard let db = try? CatalogDatabase() else {
            fatalError("Failed to access database for CharacterSettingsView")
        }
        return VoiceCharacterService(database: db)
    }

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
                    if selectedCharacterId == character.id {
                        selectedCharacterId = nil
                    } else {
                        selectedCharacterId = character.id
                    }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: character.avatarColorHex))
                            Text(character.initials)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 30, height: 30)

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

                        if selectedCharacterId == character.id {
                            Image(systemName: "chevron.down")
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
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

// MARK: - Character Detail Editor

private struct CharacterDetailEditor: View {
    @State private var name: String
    @State private var avatarColorHex: String
    @State private var systemPrompt: String
    @State private var language: String
    @State private var llmModel: String
    @State private var ttsVoice: String
    @State private var referenceAudioPath: String
    @State private var referenceText: String
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
        _avatarColorHex = State(initialValue: character.avatarColorHex)
        _systemPrompt = State(initialValue: character.systemPrompt)
        _language = State(initialValue: character.language)
        _llmModel = State(initialValue: character.llmModel)
        _ttsVoice = State(initialValue: character.ttsVoice)
        _referenceAudioPath = State(initialValue: character.referenceAudioPath)
        _referenceText = State(initialValue: character.referenceText)
    }

    var body: some View {
        TextField("Name", text: $name)
            .textFieldStyle(.roundedBorder)

        Picker("Language", selection: $language) {
            ForEach(VoiceLanguage.allCases) { lang in
                Text(lang.displayName).tag(lang.code)
            }
        }

        let pid = Preferences.shared.aiProviderId
        let models = ProviderRegistry.shared.provider(for: pid)?.models ?? []
        Picker("LLM Model", selection: $llmModel) {
            Text("Same as default").tag("")
            ForEach(models) { m in
                Text(m.name).tag(m.id)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("System Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $systemPrompt)
                .font(.system(size: 12))
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.2), width: 1)
        }

        TextField("TTS Voice", text: $ttsVoice)
            .textFieldStyle(.roundedBorder)

        HStack {
            if referenceAudioPath.isEmpty {
                Text("No reference audio")
                    .foregroundStyle(.secondary)
            } else {
                Text(URL(fileURLWithPath: referenceAudioPath).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose...") { showAudioFilePicker = true }
                .controlSize(.small)
            if !referenceAudioPath.isEmpty {
                Button("Clear") {
                    referenceAudioPath = ""
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

        if !referenceAudioPath.isEmpty {
            TextField("Reference Text", text: $referenceText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
        }

        HStack {
            Button("Save") {
                var updated = character
                updated.name = name
                updated.avatarColorHex = avatarColorHex
                updated.systemPrompt = systemPrompt
                updated.language = language
                updated.llmModel = llmModel
                updated.ttsVoice = ttsVoice
                updated.referenceAudioPath = referenceAudioPath
                updated.referenceText = referenceText
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
            let directory = CatalogDatabase.dataDirectory
                .appendingPathComponent("voice-reference-audio", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileName = url.lastPathComponent.isEmpty ? "reference-audio.wav" : url.lastPathComponent
            let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
            try fm.copyItem(at: url, to: destination)
            referenceAudioPath = destination.path
            referenceAudioImportError = nil
        } catch {
            referenceAudioImportError = "Could not import reference audio: \(error.localizedDescription)"
        }
    }
}
