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

    /// Native-script name for UI display.
    var nativeName: String {
        switch self {
        case .auto: return "Auto"
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .ar: return "العربية"
        case .lzh: return "文言文"
        }
    }

    /// All cases except `.auto`, suitable for target language selection.
    static var targetCases: [TranslationLanguage] {
        allCases.filter { $0 != .auto }
    }

    /// Vision (`VNRecognizeTextRequest`) recognition-language code for this
    /// language, used when OCR'ing a region snapshot into the source field.
    /// `nil` for `.auto` — the caller then falls back to a default language set.
    var visionLanguageCode: String? {
        switch self {
        case .auto: return nil
        case .en: return "en-US"
        case .zhHans, .lzh: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .ja: return "ja-JP"
        case .ko: return "ko-KR"
        case .fr: return "fr-FR"
        case .de: return "de-DE"
        case .es: return "es-ES"
        case .it: return "it-IT"
        case .pt: return "pt-BR"
        case .ru: return "ru-RU"
        case .ar: return "ar-SA"
        }
    }
}
