import Foundation

// MARK: - VoiceCall

struct VoiceCall: Identifiable, Hashable {
    let id: UUID
    var title: String
    var turnCount: Int
    var durationSeconds: Double
    let createdAt: Date
    var updatedAt: Date

    init(record: VoiceCallRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
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
