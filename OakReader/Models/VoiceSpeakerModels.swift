import Foundation

// MARK: - Character Config (JSON file)

struct CharacterConfig: Codable, Equatable {
    var avatar: CharacterAvatar
    var systemPrompt: String
    var language: String
    var llmModel: String
    var ttsVoice: CharacterTTSVoice
    var referenceAudio: CharacterReferenceAudio

    static let `default` = CharacterConfig(
        avatar: .init(),
        systemPrompt: "",
        language: "en",
        llmModel: "",
        ttsVoice: .init(),
        referenceAudio: .init()
    )
}

// MARK: - Avatar

struct CharacterAvatar: Codable, Equatable {
    enum AvatarType: String, Codable {
        case color
        case icon
        case image
    }

    var type: AvatarType
    var colorHex: String
    var icon: String?
    var imagePath: String?

    init(type: AvatarType = .color, colorHex: String = "#5FB236", icon: String? = nil, imagePath: String? = nil) {
        self.type = type
        self.colorHex = colorHex
        self.icon = icon
        self.imagePath = imagePath
    }
}

// MARK: - TTS Voice

struct CharacterTTSVoice: Codable, Equatable {
    var provider: String
    var voiceId: String
    var modelId: String

    init(provider: String = "", voiceId: String = "", modelId: String = "") {
        self.provider = provider
        self.voiceId = voiceId
        self.modelId = modelId
    }

    var isEmpty: Bool {
        provider.isEmpty && voiceId.isEmpty
    }
}

// MARK: - Reference Audio

struct CharacterReferenceAudio: Codable, Equatable {
    var path: String
    var text: String

    init(path: String = "", text: String = "") {
        self.path = path
        self.text = text
    }

    var url: URL? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - Character (combined DB record + JSON config)

struct Character: Identifiable, Hashable {
    let id: UUID
    let userId: String
    var name: String
    var sortOrder: Int
    let createdAt: Date
    var updatedAt: Date

    /// Config loaded from JSON file.
    var config: CharacterConfig

    /// Most recent call, populated by the view model.
    var lastCall: VoiceCall?

    init(record: CharacterRecord, config: CharacterConfig) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.userId = record.userId
        self.name = record.name
        self.sortOrder = record.sortOrder
        self.createdAt = Date(iso8601String: record.createdAt) ?? Date()
        self.updatedAt = Date(iso8601String: record.updatedAt) ?? Date()
        self.config = config
    }

    // MARK: - Convenience accessors

    var avatar: CharacterAvatar { config.avatar }
    var systemPrompt: String { config.systemPrompt }
    var language: String { config.language }
    var llmModel: String { config.llmModel }
    var ttsVoice: CharacterTTSVoice { config.ttsVoice }
    var referenceAudio: CharacterReferenceAudio { config.referenceAudio }

    var initials: String {
        let words = name.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var referenceAudioURL: URL? { referenceAudio.url }

    /// The TTS voice identifier string for the voice pipeline.
    var ttsVoiceId: String { ttsVoice.voiceId }

    // Hashable — exclude lastCall and config details
    static func == (lhs: Character, rhs: Character) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - VoiceCall

struct VoiceCall: Identifiable, Hashable {
    let id: UUID
    let characterId: UUID
    var title: String
    var turnCount: Int
    var durationSeconds: Double
    let createdAt: Date
    var updatedAt: Date

    init(record: VoiceCallRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.characterId = UUID(uuidString: record.characterId) ?? UUID()
        self.title = record.title
        self.turnCount = record.turnCount
        self.durationSeconds = record.durationSeconds
        self.createdAt = Date(iso8601String: record.createdAt) ?? Date()
        self.updatedAt = Date(iso8601String: record.updatedAt) ?? Date()
    }

    var displayTitle: String {
        title.isEmpty ? "Untitled Call" : title
    }

    var formattedDuration: String {
        let totalSeconds = Int(durationSeconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Voice Language

enum VoiceLanguage: String, CaseIterable, Identifiable {
    case en
    case zh
    case ja
    case ko
    case fr
    case de
    case es
    case ru
    case ar
    case pt

    var id: String { rawValue }

    var code: String { rawValue }

    var displayName: String {
        switch self {
        case .en: "English"
        case .zh: "Chinese (中文)"
        case .ja: "Japanese (日本語)"
        case .ko: "Korean (한국어)"
        case .fr: "French (Français)"
        case .de: "German (Deutsch)"
        case .es: "Spanish (Español)"
        case .ru: "Russian (Русский)"
        case .ar: "Arabic (العربية)"
        case .pt: "Portuguese (Português)"
        }
    }
}
