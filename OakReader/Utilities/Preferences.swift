import Foundation
import PDFKit
import OakReaderAI

final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let defaultZoomLevel = "defaultZoomLevel"
        static let displayMode = "displayMode"
        static let showSidebar = "showSidebar"
        static let sidebarMode = "sidebarMode"
        static let autoSave = "autoSave"
        static let compressionQuality = "compressionQuality"
        static let recentSignatures = "recentSignatures"
        static let defaultAnnotationColor = "defaultAnnotationColor"
        static let defaultFontName = "defaultFontName"
        static let defaultFontSize = "defaultFontSize"
        static let showStatusBar = "showStatusBar"
        static let pageDisplayBackground = "pageDisplayBackground"
        // Library preferences
        static let librarySortOrder = "librarySortOrder"
        static let librarySortAscending = "librarySortAscending"
        // Library smart collections
        static let hiddenSystemCollectionIds = "hiddenSystemCollectionIds"
        // AI preferences
        static let aiProvider = "aiProvider"
        static let aiModel = "aiModel"
        // Note editor preferences
        static let noteEditorMode = "noteEditorMode"
        static let noteEditorFontFamily = "noteEditorFontFamily"
        static let noteEditorFontSize = "noteEditorFontSize"
        static let noteEditorCodeFontFamily = "noteEditorCodeFontFamily"
        static let noteEditorLineHeight = "noteEditorLineHeight"
        static let noteEditorLineSpacing = "noteEditorLineSpacing"
        static let noteEditorLetterSpacing = "noteEditorLetterSpacing"
        static let noteEditorShowLineNumbers = "noteEditorShowLineNumbers"
        static let noteEditorRenderMath = "noteEditorRenderMath"
        static let noteEditorRenderImages = "noteEditorRenderImages"
        static let noteEditorHideSyntax = "noteEditorHideSyntax"
        static let noteEditorAccentColor = "noteEditorAccentColor"
        // YouTube preferences
        static let youtubeAIProvider = "youtubeAIProvider"
        static let youtubeAIModel = "youtubeAIModel"
        // Plugins
        static let disabledPlugins = "disabledPlugins"
        // Translation preferences
        static let translationAIProvider = "translationAIProvider"
        static let translationAIModel = "translationAIModel"
        static let translationSourceLang = "translationSourceLang"
        static let translationTargetLang = "translationTargetLang"
        // External tools
        static let ytDlpPath = "ytDlpPath"
        static let ytDlpCachedVersion = "ytDlpCachedVersion"
        static let ytDlpCachedLatestVersion = "ytDlpCachedLatestVersion"
        static let ytDlpLastVersionCheck = "ytDlpLastVersionCheck"
    }

    private init() {
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.defaultZoomLevel: 1.0,
            Keys.displayMode: PDFDisplayMode.singlePageContinuous.rawValue,
            Keys.showSidebar: true,
            Keys.sidebarMode: SidebarMode.thumbnails.rawValue,
            Keys.autoSave: true,
            Keys.compressionQuality: CompressionQuality.medium.rawValue,
            Keys.defaultFontName: PDFDefaults.defaultFontName,
            Keys.defaultFontSize: PDFDefaults.defaultFontSize,
            Keys.showStatusBar: true,
            Keys.aiProvider: AIProvider.anthropic.rawValue,
            Keys.aiModel: "",
            Keys.noteEditorMode: "edit",
            Keys.noteEditorFontFamily: ".AppleSystemUIFont",
            Keys.noteEditorFontSize: 16.0,
            Keys.noteEditorCodeFontFamily: "Menlo",
            Keys.noteEditorLineHeight: 1.3,
            Keys.noteEditorLineSpacing: 3.0,
            Keys.noteEditorLetterSpacing: 0.5,
            Keys.noteEditorShowLineNumbers: false,
            Keys.noteEditorRenderMath: true,
            Keys.noteEditorRenderImages: true,
            Keys.noteEditorHideSyntax: true,
            Keys.noteEditorAccentColor: "#0CA69A",
        ])
    }

    var defaultZoomLevel: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.defaultZoomLevel)) }
        set { defaults.set(newValue, forKey: Keys.defaultZoomLevel) }
    }

    var displayMode: PDFDisplayMode {
        get { PDFDisplayMode(rawValue: defaults.integer(forKey: Keys.displayMode)) ?? .singlePageContinuous }
        set { defaults.set(newValue.rawValue, forKey: Keys.displayMode) }
    }

    var showSidebar: Bool {
        get { defaults.bool(forKey: Keys.showSidebar) }
        set { defaults.set(newValue, forKey: Keys.showSidebar) }
    }

    var sidebarMode: SidebarMode {
        get { SidebarMode(rawValue: defaults.string(forKey: Keys.sidebarMode) ?? "") ?? .thumbnails }
        set { defaults.set(newValue.rawValue, forKey: Keys.sidebarMode) }
    }

    var autoSave: Bool {
        get { defaults.bool(forKey: Keys.autoSave) }
        set { defaults.set(newValue, forKey: Keys.autoSave) }
    }

    var compressionQuality: CompressionQuality {
        get { CompressionQuality(rawValue: defaults.string(forKey: Keys.compressionQuality) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Keys.compressionQuality) }
    }

    var defaultFontName: String {
        get { defaults.string(forKey: Keys.defaultFontName) ?? PDFDefaults.defaultFontName }
        set { defaults.set(newValue, forKey: Keys.defaultFontName) }
    }

    var defaultFontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.defaultFontSize)) }
        set { defaults.set(Double(newValue), forKey: Keys.defaultFontSize) }
    }

    var showStatusBar: Bool {
        get { defaults.bool(forKey: Keys.showStatusBar) }
        set { defaults.set(newValue, forKey: Keys.showStatusBar) }
    }

    // MARK: - Library Preferences

    var librarySortOrder: LibrarySortOrder {
        get { LibrarySortOrder(rawValue: defaults.string(forKey: Keys.librarySortOrder) ?? "") ?? .dateAdded }
        set { defaults.set(newValue.rawValue, forKey: Keys.librarySortOrder) }
    }

    var librarySortAscending: Bool {
        get { defaults.bool(forKey: Keys.librarySortAscending) }
        set { defaults.set(newValue, forKey: Keys.librarySortAscending) }
    }

    // MARK: - Library Smart Collections

    var hiddenSystemCollectionIds: Set<UUID> {
        get {
            let strings = defaults.stringArray(forKey: Keys.hiddenSystemCollectionIds) ?? []
            return Set(strings.compactMap { UUID(uuidString: $0) })
        }
        set {
            defaults.set(newValue.map(\.uuidString), forKey: Keys.hiddenSystemCollectionIds)
        }
    }

    // MARK: - Plugins

    var disabledPlugins: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.disabledPlugins) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.disabledPlugins) }
    }

    func isPluginEnabled(_ plugin: Plugin) -> Bool {
        !disabledPlugins.contains(plugin.rawValue)
    }

    func setPlugin(_ plugin: Plugin, enabled: Bool) {
        var disabled = disabledPlugins
        if enabled {
            disabled.remove(plugin.rawValue)
        } else {
            disabled.insert(plugin.rawValue)
        }
        disabledPlugins = disabled
    }

    // MARK: - AI Preferences

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "") ?? .anthropic }
        set { defaults.set(newValue.rawValue, forKey: Keys.aiProvider) }
    }

    var aiModel: String {
        get { defaults.string(forKey: Keys.aiModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.aiModel) }
    }

    // MARK: - Note Editor Preferences

    var noteEditorMode: String {
        get { defaults.string(forKey: Keys.noteEditorMode) ?? "edit" }
        set { defaults.set(newValue, forKey: Keys.noteEditorMode) }
    }

    var noteEditorFontFamily: String {
        get { defaults.string(forKey: Keys.noteEditorFontFamily) ?? ".AppleSystemUIFont" }
        set { defaults.set(newValue, forKey: Keys.noteEditorFontFamily) }
    }

    var noteEditorFontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.noteEditorFontSize)) }
        set { defaults.set(Double(newValue), forKey: Keys.noteEditorFontSize) }
    }

    var noteEditorCodeFontFamily: String {
        get { defaults.string(forKey: Keys.noteEditorCodeFontFamily) ?? "Menlo" }
        set { defaults.set(newValue, forKey: Keys.noteEditorCodeFontFamily) }
    }

    var noteEditorLineHeight: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.noteEditorLineHeight)) }
        set { defaults.set(Double(newValue), forKey: Keys.noteEditorLineHeight) }
    }

    var noteEditorLineSpacing: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.noteEditorLineSpacing)) }
        set { defaults.set(Double(newValue), forKey: Keys.noteEditorLineSpacing) }
    }

    var noteEditorLetterSpacing: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.noteEditorLetterSpacing)) }
        set { defaults.set(Double(newValue), forKey: Keys.noteEditorLetterSpacing) }
    }

    var noteEditorShowLineNumbers: Bool {
        get { defaults.bool(forKey: Keys.noteEditorShowLineNumbers) }
        set { defaults.set(newValue, forKey: Keys.noteEditorShowLineNumbers) }
    }

    var noteEditorRenderMath: Bool {
        get { defaults.bool(forKey: Keys.noteEditorRenderMath) }
        set { defaults.set(newValue, forKey: Keys.noteEditorRenderMath) }
    }

    var noteEditorRenderImages: Bool {
        get { defaults.bool(forKey: Keys.noteEditorRenderImages) }
        set { defaults.set(newValue, forKey: Keys.noteEditorRenderImages) }
    }

    var noteEditorHideSyntax: Bool {
        get { defaults.bool(forKey: Keys.noteEditorHideSyntax) }
        set { defaults.set(newValue, forKey: Keys.noteEditorHideSyntax) }
    }

    var noteEditorAccentColor: String {
        get { defaults.string(forKey: Keys.noteEditorAccentColor) ?? "#0CA69A" }
        set { defaults.set(newValue, forKey: Keys.noteEditorAccentColor) }
    }

    // MARK: - YouTube Preferences

    var youtubeAIProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: Keys.youtubeAIProvider) ?? "") ?? aiProvider }
        set { defaults.set(newValue.rawValue, forKey: Keys.youtubeAIProvider) }
    }

    var youtubeAIModel: String {
        get { defaults.string(forKey: Keys.youtubeAIModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.youtubeAIModel) }
    }

    static var chapterPromptURL: URL {
        CatalogDatabase.dataDirectory
            .appendingPathComponent("prompts")
            .appendingPathComponent("chapter-generation.md")
    }

    static var sectionPromptURL: URL {
        CatalogDatabase.dataDirectory
            .appendingPathComponent("prompts")
            .appendingPathComponent("section-generation.md")
    }

    // MARK: - Translation Preferences

    var translationAIProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: Keys.translationAIProvider) ?? "") ?? aiProvider }
        set { defaults.set(newValue.rawValue, forKey: Keys.translationAIProvider) }
    }

    var translationAIModel: String {
        get { defaults.string(forKey: Keys.translationAIModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.translationAIModel) }
    }

    var translationSourceLang: TranslationLanguage {
        get { TranslationLanguage(rawValue: defaults.string(forKey: Keys.translationSourceLang) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Keys.translationSourceLang) }
    }

    var translationTargetLang: TranslationLanguage {
        get { TranslationLanguage(rawValue: defaults.string(forKey: Keys.translationTargetLang) ?? "") ?? .zhHans }
        set { defaults.set(newValue.rawValue, forKey: Keys.translationTargetLang) }
    }

    // MARK: - External Tools

    var ytDlpPath: String {
        get { defaults.string(forKey: Keys.ytDlpPath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.ytDlpPath) }
    }

    /// Cached local yt-dlp version (avoids running the binary every time settings opens).
    var ytDlpCachedVersion: String? {
        get { defaults.string(forKey: Keys.ytDlpCachedVersion) }
        set { defaults.set(newValue, forKey: Keys.ytDlpCachedVersion) }
    }

    var ytDlpCachedLatestVersion: String? {
        get { defaults.string(forKey: Keys.ytDlpCachedLatestVersion) }
        set { defaults.set(newValue, forKey: Keys.ytDlpCachedLatestVersion) }
    }

    var ytDlpLastVersionCheck: Date? {
        get { defaults.object(forKey: Keys.ytDlpLastVersionCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.ytDlpLastVersionCheck) }
    }
}
