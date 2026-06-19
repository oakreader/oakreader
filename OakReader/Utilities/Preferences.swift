import Foundation
import OakAI
import PDFKit

// MARK: - Pronunciation Accent

enum PronunciationAccent: String, CaseIterable, Identifiable {
    case british, american

    var id: String { rawValue }

    var label: String {
        switch self {
        case .british: "British"
        case .american: "American"
        }
    }

    var ipaLabel: String {
        switch self {
        case .british: "BrE"
        case .american: "AmE"
        }
    }
}

// MARK: - Agent Permission Level

/// Controls when tool calls require user confirmation.
enum AgentPermissionLevel: String, CaseIterable, Identifiable {
    /// Full permission — all tools run freely.
    case full
    /// Smart permission — read-only tools auto-approved; write/dangerous require confirmation.
    case smart
    /// Restricted permission — every tool call requires confirmation.
    case restricted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: "Full Access"
        case .smart: "Smart Approval"
        case .restricted: "Always Ask"
        }
    }

    var description: String {
        switch self {
        case .full: "All tools run without asking"
        case .smart: "Read tools auto-approved, write tools ask"
        case .restricted: "Every tool call requires approval"
        }
    }

}

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
        static let defaultFontName = "defaultFontName"
        static let defaultFontSize = "defaultFontSize"
        static let showStatusBar = "showStatusBar"
        // Privacy
        static let analyticsEnabled = "analyticsEnabled"
        // Library preferences
        static let librarySortOrder = "librarySortOrder"
        static let librarySortAscending = "librarySortAscending"
        static let libraryViewMode = "libraryViewMode"
        // Library smart collections
        static let hiddenSystemCollectionIds = "hiddenSystemCollectionIds"
        // AI preferences
        static let aiProvider = "aiProvider"
        static let aiModel = "aiModel"
        /// Optional cheaper/faster model for the research subagent (empty = inherit chat model).
        static let researchModel = "researchModel"
        // Plugins (extensions)
        static let disabledPlugins = "disabledPlugins"
        static let explicitlyToggledPlugins = "explicitlyToggledPlugins"
        // Translation preferences
        static let translationAIProvider = "translationAIProvider"
        static let translationAIModel = "translationAIModel"
        static let translationSourceLang = "translationSourceLang"
        static let translationTargetLang = "translationTargetLang"
        static let pronunciationAccent = "pronunciationAccent"
        // Agent tools
        static let agentToolsEnabled = "agentToolsEnabled"
        static let agentReadFileEnabled = "agentReadFileEnabled"
        static let agentWriteFileEnabled = "agentWriteFileEnabled"
        static let agentPermissionLevel = "agentPermissionLevel"
        // ChatGPT `bio`-style memory: the agent saves durable facts about the user
        // (one global profile) and injects them into every conversation.
        static let memoryEnabled = "memoryEnabled"
        // Thinking budget
        static let thinkingBudget = "thinkingBudget"
        static let thinkingEffort = "thinkingEffort"
        // Chat font
        static let chatFontSize = "chatFontSize"
        static let chatLineHeightScale = "chatLineHeightScale"
        // Voice AI
        static let voiceTTSVoice = "voiceTTSVoice"
        static let voiceReferenceAudioPath = "voiceReferenceAudioPath"
        static let voiceReferenceText = "voiceReferenceText"
        static let voiceLLMModel = "voiceLLMModel"
        static let voiceLanguage = "voiceLanguage"
        static let voiceInputDeviceUID = "voiceInputDeviceUID"
        static let voiceOutputDeviceUID = "voiceOutputDeviceUID"
        // Cloud voice providers
        static let voiceSTTProvider = "voiceSTTProvider"
        static let voiceTTSProvider = "voiceTTSProvider"
        static let elevenLabsAPIKey = "elevenLabsAPIKey"
        static let elevenLabsVoiceId = "elevenLabsVoiceId"
        static let elevenLabsTTSModelId = "elevenLabsTTSModelId"
        static let openAITTSVoice = "openAITTSVoice"
        static let geminiTTSVoice = "geminiTTSVoice"
        static let fishAudioAPIKey = "fishAudioAPIKey"
        static let fishAudioReferenceId = "fishAudioReferenceId"
        // Disabled models
        static let disabledModelIds = "disabledModelIds"
        // Appearance
        static let appearanceMode = "appearanceMode"
        // Web search
        static let webSearchProvider = "webSearchProvider"
        // Browser search engine (new-tab omnibox + address bar)
        static let browserSearchEngine = "browserSearchEngine"
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
            Keys.analyticsEnabled: true,
            Keys.aiProvider: "anthropic",
            Keys.aiModel: "",
            Keys.chatFontSize: 14.0,
            Keys.chatLineHeightScale: 1.35,
            Keys.agentToolsEnabled: true,
            Keys.agentReadFileEnabled: true,
            Keys.agentWriteFileEnabled: true,
            Keys.agentPermissionLevel: AgentPermissionLevel.smart.rawValue,
            Keys.thinkingBudget: 10000,
            Keys.appearanceMode: "system",
            Keys.libraryViewMode: LibraryViewMode.list.rawValue,
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

    /// Whether anonymous product analytics (PostHog) may be sent. Opt-out; defaults on.
    var analyticsEnabled: Bool {
        get { defaults.bool(forKey: Keys.analyticsEnabled) }
        set { defaults.set(newValue, forKey: Keys.analyticsEnabled) }
    }

    // MARK: - Chat Font

    /// Base font size for the AI chat markdown renderer. Code, headings, and line
    /// height all scale from this (see `MarkdownTheme.oak(fontSize:lineHeightScale:)`).
    var chatFontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.chatFontSize)) }
        set { defaults.set(Double(newValue), forKey: Keys.chatFontSize) }
    }

    /// Line-spacing multiplier for the AI chat markdown renderer (line height =
    /// chatFontSize × this). Scales with the font so spacing stays proportional.
    var chatLineHeightScale: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.chatLineHeightScale)) }
        set { defaults.set(Double(newValue), forKey: Keys.chatLineHeightScale) }
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

    var libraryViewMode: LibraryViewMode {
        get { LibraryViewMode(rawValue: defaults.string(forKey: Keys.libraryViewMode) ?? "") ?? .list }
        set { defaults.set(newValue.rawValue, forKey: Keys.libraryViewMode) }
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

    /// Set of extension raw values that the user has explicitly toggled (either on or off).
    private var explicitlyToggledPlugins: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.explicitlyToggledPlugins) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.explicitlyToggledPlugins) }
    }

    func isExtensionEnabled(_ ext: AppExtension) -> Bool {
        if explicitlyToggledPlugins.contains(ext.rawValue) {
            // User has explicitly toggled this extension — use the disabled set.
            return !disabledPlugins.contains(ext.rawValue)
        }
        // Never explicitly toggled — use the default.
        return ext.enabledByDefault
    }

    func setExtension(_ ext: AppExtension, enabled: Bool) {
        var toggled = explicitlyToggledPlugins
        toggled.insert(ext.rawValue)
        explicitlyToggledPlugins = toggled

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

    /// Optional cheaper/faster model id for the research subagent's loop.
    /// Empty means inherit the main chat model.
    var researchModel: String {
        get { defaults.string(forKey: Keys.researchModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.researchModel) }
    }

    // MARK: - Memory

    /// Whether the agent remembers durable facts about the user across
    /// conversations (saved via the `manage_memory` tool, injected into every
    /// chat). Defaults to ON. When off, the tool and profile are not present.
    var memoryEnabled: Bool {
        get { defaults.object(forKey: Keys.memoryEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.memoryEnabled) }
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

    var pronunciationAccent: PronunciationAccent {
        get { PronunciationAccent(rawValue: defaults.string(forKey: Keys.pronunciationAccent) ?? "") ?? .british }
        set { defaults.set(newValue.rawValue, forKey: Keys.pronunciationAccent) }
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

    var agentPermissionLevel: AgentPermissionLevel {
        get {
            let raw = defaults.string(forKey: Keys.agentPermissionLevel) ?? ""
            return AgentPermissionLevel(rawValue: raw) ?? .smart
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.agentPermissionLevel) }
    }

    /// Extended thinking token budget for reasoning models.
    var thinkingBudget: Int {
        get {
            let value = defaults.integer(forKey: Keys.thinkingBudget)
            return value > 0 ? value : 10000
        }
        set { defaults.set(newValue, forKey: Keys.thinkingBudget) }
    }

    /// Thinking effort level for reasoning models ("off", "low", "medium", "high", "max").
    /// "off" disables thinking entirely. Other values map to API effort levels.
    /// Defaults to "low": interactive chat should answer fast (Dia-like). High effort
    /// spends seconds reasoning before the first visible token — reserve it for hard
    /// questions via the model menu, don't pay it on every message.
    var thinkingEffort: String {
        get { defaults.string(forKey: Keys.thinkingEffort) ?? "low" }
        set { defaults.set(newValue, forKey: Keys.thinkingEffort) }
    }

    // MARK: - Voice AI Preferences

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

    // MARK: - Disabled Models

    /// Model IDs that the user has toggled off in provider settings.
    var disabledModelIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.disabledModelIds) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.disabledModelIds) }
    }

    func isModelEnabled(_ modelId: String) -> Bool {
        !disabledModelIds.contains(modelId)
    }

    func setModel(_ modelId: String, enabled: Bool) {
        var disabled = disabledModelIds
        if enabled {
            disabled.remove(modelId)
        } else {
            disabled.insert(modelId)
        }
        disabledModelIds = disabled
    }

    // MARK: - Cloud Voice Provider Preferences

    /// STT provider type (currently only "elevenlabs").
    var voiceSTTProvider: String {
        get { defaults.string(forKey: Keys.voiceSTTProvider) ?? "elevenlabs" }
        set { defaults.set(newValue, forKey: Keys.voiceSTTProvider) }
    }

    /// TTS provider type (currently only "elevenlabs").
    var voiceTTSProvider: String {
        get { defaults.string(forKey: Keys.voiceTTSProvider) ?? "elevenlabs" }
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

    /// OpenAI TTS voice name (e.g. "alloy", "nova"). Uses the OpenAI chat API key.
    var openAITTSVoice: String {
        get { defaults.string(forKey: Keys.openAITTSVoice) ?? "alloy" }
        set { defaults.set(newValue, forKey: Keys.openAITTSVoice) }
    }

    /// Gemini TTS voice name (e.g. "Kore"). Uses the Google/Gemini chat API key.
    var geminiTTSVoice: String {
        get { defaults.string(forKey: Keys.geminiTTSVoice) ?? "Kore" }
        set { defaults.set(newValue, forKey: Keys.geminiTTSVoice) }
    }

    /// Fish Audio API key (shared by STT and TTS).
    var fishAudioAPIKey: String {
        get { defaults.string(forKey: Keys.fishAudioAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.fishAudioAPIKey) }
    }

    /// Fish Audio voice model reference id (empty uses the account default).
    var fishAudioReferenceId: String {
        get { defaults.string(forKey: Keys.fishAudioReferenceId) ?? "" }
        set { defaults.set(newValue, forKey: Keys.fishAudioReferenceId) }
    }

    /// Per-provider base-URL override for cloud voice (TTS/STT), so OpenAI/Gemini
    /// voice can be pointed at a proxy or relay. Empty uses the provider's default.
    /// Keyed by `VoiceProviderType.rawValue` (e.g. "openai", "gemini").
    func voiceBaseURL(forProvider id: String) -> String {
        defaults.string(forKey: "voiceBaseURL.\(id)") ?? ""
    }

    func setVoiceBaseURL(_ value: String, forProvider id: String) {
        defaults.set(value, forKey: "voiceBaseURL.\(id)")
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

    // MARK: - Web Search

    /// Selected web search provider ID, or "auto" for automatic resolution.
    var webSearchProviderId: String {
        get { defaults.string(forKey: Keys.webSearchProvider) ?? "auto" }
        set { defaults.set(newValue, forKey: Keys.webSearchProvider) }
    }

    /// Default search engine for the new-tab omnibox and the web address bar.
    var browserSearchEngine: BrowserSearchEngine {
        get {
            defaults.string(forKey: Keys.browserSearchEngine)
                .flatMap(BrowserSearchEngine.init(rawValue:)) ?? .google
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.browserSearchEngine) }
    }

}

