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
}
