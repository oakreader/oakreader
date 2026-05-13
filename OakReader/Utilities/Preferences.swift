import Foundation
import PDFKit

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
        // Plugins (extensions)
        static let disabledPlugins = "disabledPlugins"
        // Translation preferences
        static let translationAIProvider = "translationAIProvider"
        static let translationAIModel = "translationAIModel"
        static let translationSourceLang = "translationSourceLang"
        static let translationTargetLang = "translationTargetLang"
        // Agent tools
        static let agentToolsEnabled = "agentToolsEnabled"
        static let agentReadFileEnabled = "agentReadFileEnabled"
        static let agentWriteFileEnabled = "agentWriteFileEnabled"
        static let agentRequireConfirmation = "agentRequireConfirmation"
        // Global font
        static let globalFontFamily = "globalFontFamily"
        static let globalFontSize = "globalFontSize"
        static let noteEditorFontOverridden = "noteEditorFontOverridden"
        // Voice AI
        static let voiceSTTModel = "voiceSTTModel"
        static let voiceTTSModel = "voiceTTSModel"
        static let voiceVADModel = "voiceVADModel"
        static let voiceTurnDetectorEnabled = "voiceTurnDetectorEnabled"
        static let voiceTTSVoice = "voiceTTSVoice"
        static let voiceReferenceAudioPath = "voiceReferenceAudioPath"
        static let voiceReferenceText = "voiceReferenceText"
        static let voiceLLMModel = "voiceLLMModel"
        static let voiceLanguage = "voiceLanguage"
        static let voiceLiveTranscription = "voiceLiveTranscription"
        static let voiceInputDeviceUID = "voiceInputDeviceUID"
        static let voiceOutputDeviceUID = "voiceOutputDeviceUID"
        static let hfEndpoint = "hfEndpoint"
        // ElevenLabs cloud providers
        static let voiceSTTProvider = "voiceSTTProvider"
        static let voiceTTSProvider = "voiceTTSProvider"
        static let elevenLabsAPIKey = "elevenLabsAPIKey"
        static let elevenLabsVoiceId = "elevenLabsVoiceId"
        static let elevenLabsTTSModelId = "elevenLabsTTSModelId"
        static let elevenLabsSTTModelId = "elevenLabsSTTModelId"
        // Embedding
        static let embeddingModel = "embeddingModel"
        // Appearance
        static let appearanceMode = "appearanceMode"
        // External tools
        static let ytDlpPath = "ytDlpPath"
        static let ytDlpCachedVersion = "ytDlpCachedVersion"
        static let ytDlpCachedLatestVersion = "ytDlpCachedLatestVersion"
        static let ytDlpLastVersionCheck = "ytDlpLastVersionCheck"
    }

    private init() {
        registerDefaults()
        migrateNoteEditorFontOverride()
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
            Keys.aiProvider: "anthropic",
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
            Keys.globalFontFamily: "system",
            Keys.globalFontSize: 14.0,
            Keys.noteEditorFontOverridden: false,
            Keys.agentToolsEnabled: true,
            Keys.agentReadFileEnabled: true,
            Keys.agentWriteFileEnabled: true,
            Keys.agentRequireConfirmation: true,
            Keys.appearanceMode: "system",
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

    // MARK: - Global Font

    var globalFontFamily: String {
        get { defaults.string(forKey: Keys.globalFontFamily) ?? "system" }
        set { defaults.set(newValue, forKey: Keys.globalFontFamily) }
    }

    var globalFontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.globalFontSize)) }
        set { defaults.set(Double(newValue), forKey: Keys.globalFontSize) }
    }

    var noteEditorFontOverridden: Bool {
        get { defaults.bool(forKey: Keys.noteEditorFontOverridden) }
        set { defaults.set(newValue, forKey: Keys.noteEditorFontOverridden) }
    }

    /// Effective font family for the note editor — note-specific if overridden, global otherwise.
    var effectiveNoteEditorFontFamily: String {
        if noteEditorFontOverridden {
            return noteEditorFontFamily
        }
        return FontFamily(rawValue: globalFontFamily)?.fontName ?? ".AppleSystemUIFont"
    }

    /// Effective font size for the note editor — note-specific if overridden, global otherwise.
    var effectiveNoteEditorFontSize: CGFloat {
        if noteEditorFontOverridden {
            return noteEditorFontSize
        }
        return globalFontSize
    }

    /// One-time migration: if user previously customized note font, mark it as overridden.
    private func migrateNoteEditorFontOverride() {
        let migrationKey = "noteEditorFontOverrideMigrated"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        let currentFont = defaults.string(forKey: Keys.noteEditorFontFamily) ?? ".AppleSystemUIFont"
        let currentSize = defaults.double(forKey: Keys.noteEditorFontSize)
        if currentFont != ".AppleSystemUIFont" || (currentSize != 0 && currentSize != 16.0) {
            defaults.set(true, forKey: Keys.noteEditorFontOverridden)
        }
    }

    // MARK: - Appearance

    var appearanceMode: String {
        get { defaults.string(forKey: Keys.appearanceMode) ?? "system" }
        set { defaults.set(newValue, forKey: Keys.appearanceMode) }
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

    /// Posted when a built-in app extension is toggled. Settings sidebar listens for this
    /// instead of the blanket UserDefaults.didChangeNotification.
    static let appExtensionToggleNotification = Notification.Name("OakReader.pluginToggle")

    var disabledPlugins: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.disabledPlugins) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.disabledPlugins) }
    }

    func isExtensionEnabled(_ ext: AppExtension) -> Bool {
        !disabledPlugins.contains(ext.rawValue)
    }

    func setExtension(_ ext: AppExtension, enabled: Bool) {
        var disabled = disabledPlugins
        if enabled {
            disabled.remove(ext.rawValue)
        } else {
            disabled.insert(ext.rawValue)
        }
        disabledPlugins = disabled
        NotificationCenter.default.post(name: Self.appExtensionToggleNotification, object: nil)
    }

    // MARK: - AI Preferences

    var aiProviderId: String {
        get { defaults.string(forKey: Keys.aiProvider) ?? "anthropic" }
        set { defaults.set(newValue, forKey: Keys.aiProvider) }
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

    var youtubeAIProviderId: String {
        get { defaults.string(forKey: Keys.youtubeAIProvider) ?? aiProviderId }
        set { defaults.set(newValue, forKey: Keys.youtubeAIProvider) }
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

    var translationAIProviderId: String {
        get { defaults.string(forKey: Keys.translationAIProvider) ?? aiProviderId }
        set { defaults.set(newValue, forKey: Keys.translationAIProvider) }
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

    // MARK: - Agent Tools

    var agentToolsEnabled: Bool {
        get { defaults.bool(forKey: Keys.agentToolsEnabled) }
        set { defaults.set(newValue, forKey: Keys.agentToolsEnabled) }
    }

    var agentReadFileEnabled: Bool {
        get { defaults.bool(forKey: Keys.agentReadFileEnabled) }
        set { defaults.set(newValue, forKey: Keys.agentReadFileEnabled) }
    }

    var agentWriteFileEnabled: Bool {
        get { defaults.bool(forKey: Keys.agentWriteFileEnabled) }
        set { defaults.set(newValue, forKey: Keys.agentWriteFileEnabled) }
    }

    var agentRequireConfirmation: Bool {
        get { defaults.bool(forKey: Keys.agentRequireConfirmation) }
        set { defaults.set(newValue, forKey: Keys.agentRequireConfirmation) }
    }

    // MARK: - Voice AI Preferences

    var voiceSTTModel: String {
        get { defaults.string(forKey: Keys.voiceSTTModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceSTTModel) }
    }

    var voiceTTSModel: String {
        get { defaults.string(forKey: Keys.voiceTTSModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceTTSModel) }
    }

    var voiceVADModel: String {
        get { defaults.string(forKey: Keys.voiceVADModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceVADModel) }
    }

    var voiceTurnDetectorEnabled: Bool {
        get { defaults.object(forKey: Keys.voiceTurnDetectorEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.voiceTurnDetectorEnabled) }
    }

    var voiceTTSVoice: String {
        get { defaults.string(forKey: Keys.voiceTTSVoice) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceTTSVoice) }
    }

    var voiceReferenceAudioPath: String {
        get { defaults.string(forKey: Keys.voiceReferenceAudioPath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceReferenceAudioPath) }
    }

    /// Transcript of the reference audio clip (required for Qwen3-TTS voice cloning).
    var voiceReferenceText: String {
        get { defaults.string(forKey: Keys.voiceReferenceText) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceReferenceText) }
    }

    /// LLM model override for voice conversations (empty = same as AI Chat).
    var voiceLLMModel: String {
        get { defaults.string(forKey: Keys.voiceLLMModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceLLMModel) }
    }

    /// Language code for voice STT/TTS (e.g. "en", "zh", "ja"). Defaults to English.
    var voiceLanguage: String {
        get { defaults.string(forKey: Keys.voiceLanguage) ?? "en" }
        set { defaults.set(newValue, forKey: Keys.voiceLanguage) }
    }

    /// Enable live (streaming) transcription during speech. Defaults to true.
    var voiceLiveTranscription: Bool {
        get { defaults.object(forKey: Keys.voiceLiveTranscription) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.voiceLiveTranscription) }
    }

    /// Persistent UID of the selected input (microphone) device. Empty = system default.
    var voiceInputDeviceUID: String {
        get { defaults.string(forKey: Keys.voiceInputDeviceUID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceInputDeviceUID) }
    }

    /// Persistent UID of the selected output (speaker) device. Empty = system default.
    var voiceOutputDeviceUID: String {
        get { defaults.string(forKey: Keys.voiceOutputDeviceUID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceOutputDeviceUID) }
    }

    /// Custom HuggingFace endpoint URL (e.g. "https://hf-mirror.com" for China).
    /// Empty string means default (https://huggingface.co).
    var hfEndpoint: String {
        get { defaults.string(forKey: Keys.hfEndpoint) ?? "" }
        set { defaults.set(newValue, forKey: Keys.hfEndpoint) }
    }

    // MARK: - Embedding Model

    var embeddingModel: String {
        get { defaults.string(forKey: Keys.embeddingModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.embeddingModel) }
    }

    // MARK: - ElevenLabs Cloud Provider Preferences

    /// STT provider type: "on_device" or "elevenlabs".
    var voiceSTTProvider: String {
        get { defaults.string(forKey: Keys.voiceSTTProvider) ?? "on_device" }
        set { defaults.set(newValue, forKey: Keys.voiceSTTProvider) }
    }

    /// TTS provider type: "on_device" or "elevenlabs".
    var voiceTTSProvider: String {
        get { defaults.string(forKey: Keys.voiceTTSProvider) ?? "on_device" }
        set { defaults.set(newValue, forKey: Keys.voiceTTSProvider) }
    }

    /// ElevenLabs API key (shared by STT and TTS).
    var elevenLabsAPIKey: String {
        get { defaults.string(forKey: Keys.elevenLabsAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.elevenLabsAPIKey) }
    }

    /// ElevenLabs voice ID for TTS.
    var elevenLabsVoiceId: String {
        get { defaults.string(forKey: Keys.elevenLabsVoiceId) ?? "" }
        set { defaults.set(newValue, forKey: Keys.elevenLabsVoiceId) }
    }

    /// ElevenLabs TTS model ID.
    var elevenLabsTTSModelId: String {
        get { defaults.string(forKey: Keys.elevenLabsTTSModelId) ?? "eleven_turbo_v2_5" }
        set { defaults.set(newValue, forKey: Keys.elevenLabsTTSModelId) }
    }

    /// ElevenLabs STT model ID.
    var elevenLabsSTTModelId: String {
        get { defaults.string(forKey: Keys.elevenLabsSTTModelId) ?? "scribe_v2_realtime" }
        set { defaults.set(newValue, forKey: Keys.elevenLabsSTTModelId) }
    }

    var voiceReferenceAudioURL: URL? {
        let path = voiceReferenceAudioPath
        if !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Fall back to bundled default voice
        return Bundle.main.url(forResource: "grant_voice", withExtension: "wav")
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
