import Foundation
import PDFKit
import AppKit

enum EPUBTheme: String, CaseIterable {
    case light
    case sepia
    case dark

    var label: String {
        switch self {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        }
    }

    var backgroundColor: String {
        switch self {
        case .light: return "#ffffff"
        case .sepia: return "#f4ecd8"
        case .dark: return "#1e1e1e"
        }
    }

    var textColor: String {
        switch self {
        case .light: return "#333333"
        case .sepia: return "#5b4636"
        case .dark: return "#d4d4d4"
        }
    }

    var linkColor: String {
        switch self {
        case .light: return "#0068da"
        case .sepia: return "#7b5e3f"
        case .dark: return "#6cb4ee"
        }
    }
}

@Observable
class DocumentState {
    var currentPageIndex: Int = 0
    var zoomLevel: CGFloat = 1.0
    var displayMode: PDFDisplayMode = .singlePageContinuous
    var searchQuery: String = ""
    var searchResults: [PDFSelection] = []
    var currentSearchIndex: Int = 0
    var selectedAnnotation: PDFAnnotation?
    var editorMode: EditorMode = .viewer
    var sidebarMode: SidebarMode = .thumbnails
    var mediaSidebarMode: MediaSidebarMode = .outline
    var currentSpineIndex: Int = 0
    /// Incremented on every TOC click to force the viewer to reload even when spine index is unchanged.
    var epubNavigationToken: Int = 0

    // EPUB Reader Settings (loaded from Preferences on init)
    var epubFontSize: Int = 18
    var epubFontFamily: String = "Palatino"
    var epubTheme: EPUBTheme = .light
    var epubMargin: Int = 60
    var epubLineHeight: Double = 1.8

    var isSidebarVisible: Bool = true
    var rightPanelMode: RightPanelMode? = nil
    var isLoading: Bool = false
    var errorMessage: String?
    var showError: Bool = false

    // Selection state for AI chat integration
    var selectedText: String?

    func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
