import Foundation

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case auto
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case fr
    case de
    case es
    case it
    case pt
    case ru
    case ar
    case lzh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .en: return "English"
        case .zhHans: return "Simplified Chinese"
        case .zhHant: return "Traditional Chinese"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .fr: return "French"
        case .de: return "German"
        case .es: return "Spanish"
        case .it: return "Italian"
        case .pt: return "Portuguese"
        case .ru: return "Russian"
        case .ar: return "Arabic"
        case .lzh: return "Classical Chinese"
        }
    }

    /// All cases except `.auto`, suitable for target language selection.
    static var targetCases: [TranslationLanguage] {
        allCases.filter { $0 != .auto }
    }
}
