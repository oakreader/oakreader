import Foundation
import PDFKit
import AppKit

enum EPUBTheme: String, CaseIterable {
    case original
    case paper
    case bold
    case calm
    case focus
    case quiet

    var label: String {
        switch self {
        case .original: return "Original"
        case .paper: return "Paper"
        case .bold: return "Bold"
        case .calm: return "Calm"
        case .focus: return "Focus"
        case .quiet: return "Quiet"
        }
    }

    var backgroundColor: String {
        switch self {
        case .original: return "#ffffff"
        case .paper: return "#f8f3e8"
        case .bold: return "#ffffff"
        case .calm: return "#e8ede8"
        case .focus: return "#e4e8ec"
        case .quiet: return "#eeeae5"
        }
    }

    var textColor: String {
        switch self {
        case .original: return "#1d1d1f"
        case .paper: return "#3b2e1a"
        case .bold: return "#000000"
        case .calm: return "#2d3a2d"
        case .focus: return "#1c2733"
        case .quiet: return "#3d3832"
        }
    }

    var linkColor: String {
        switch self {
        case .original: return "#007aff"
        case .paper: return "#8b6914"
        case .bold: return "#0050d0"
        case .calm: return "#2e7d32"
        case .focus: return "#1565c0"
        case .quiet: return "#6d584a"
        }
    }

    var isDark: Bool { false }
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
    var epubTheme: EPUBTheme = .original
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
