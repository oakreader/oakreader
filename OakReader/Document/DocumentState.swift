import Foundation
import PDFKit
import AppKit

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
