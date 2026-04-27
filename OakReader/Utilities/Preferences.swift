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
        // AI preferences
        static let aiProvider = "aiProvider"
        static let aiModel = "aiModel"
        // Note editor preferences
        static let noteEditorFontFamily = "noteEditorFontFamily"
        static let noteEditorFontSize = "noteEditorFontSize"
        static let noteEditorCodeFontFamily = "noteEditorCodeFontFamily"
        static let noteEditorLineHeight = "noteEditorLineHeight"
        static let noteEditorShowLineNumbers = "noteEditorShowLineNumbers"
        static let noteEditorRenderMath = "noteEditorRenderMath"
        static let noteEditorRenderImages = "noteEditorRenderImages"
        static let noteEditorHideSyntax = "noteEditorHideSyntax"
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
            Keys.noteEditorFontFamily: "'Georgia', 'Times New Roman', 'Iowan Old Style', serif",
            Keys.noteEditorFontSize: 17.0,
            Keys.noteEditorCodeFontFamily: "'Iosevka Mono', 'SF Mono', Menlo, Monaco, monospace",
            Keys.noteEditorLineHeight: 1.75,
            Keys.noteEditorShowLineNumbers: false,
            Keys.noteEditorRenderMath: true,
            Keys.noteEditorRenderImages: true,
            Keys.noteEditorHideSyntax: true,
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

    var noteEditorFontFamily: String {
        get { defaults.string(forKey: Keys.noteEditorFontFamily) ?? "'Georgia', 'Times New Roman', serif" }
        set { defaults.set(newValue, forKey: Keys.noteEditorFontFamily) }
    }

    var noteEditorFontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.noteEditorFontSize)) }
        set { defaults.set(Double(newValue), forKey: Keys.noteEditorFontSize) }
    }

    var noteEditorCodeFontFamily: String {
        get { defaults.string(forKey: Keys.noteEditorCodeFontFamily) ?? "'Iosevka Mono', 'SF Mono', monospace" }
        set { defaults.set(newValue, forKey: Keys.noteEditorCodeFontFamily) }
    }

    var noteEditorLineHeight: CGFloat {
        get { CGFloat(defaults.double(forKey: Keys.noteEditorLineHeight)) }
        set { defaults.set(Double(newValue), forKey: Keys.noteEditorLineHeight) }
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
}
