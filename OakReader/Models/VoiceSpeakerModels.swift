import Foundation

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
