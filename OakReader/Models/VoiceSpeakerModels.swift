import Foundation

// MARK: - Character

struct Character: Identifiable, Hashable {
    let id: UUID
    let userId: String
    var name: String
    var avatarColorHex: String
    var ttsVoice: String
    var referenceAudioPath: String
    var referenceText: String
    var language: String
    var llmModel: String
    var systemPrompt: String
    var sortOrder: Int
    let createdAt: Date
    var updatedAt: Date

    /// Most recent call, populated by the view model.
    var lastCall: VoiceCall?

    init(record: CharacterRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.userId = record.userId
        self.name = record.name
        self.avatarColorHex = record.avatarColorHex
        self.ttsVoice = record.ttsVoice
        self.referenceAudioPath = record.referenceAudioPath
        self.referenceText = record.referenceText
        self.language = record.language
        self.llmModel = record.llmModel
        self.systemPrompt = record.systemPrompt
        self.sortOrder = record.sortOrder
        self.createdAt = Date(iso8601String: record.createdAt) ?? Date()
        self.updatedAt = Date(iso8601String: record.updatedAt) ?? Date()
    }

    var initials: String {
        let words = name.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var referenceAudioURL: URL? {
        guard !referenceAudioPath.isEmpty else { return nil }
        return URL(fileURLWithPath: referenceAudioPath)
    }

    // Hashable — exclude lastCall (optional associated data)
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
