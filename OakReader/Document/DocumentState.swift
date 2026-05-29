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

    var isSidebarVisible: Bool = true
    var rightPanelMode: RightPanelMode? = nil
    var isZenMode: Bool = false
    var isPresentationMode: Bool = false
    var presentationSavedState: PresentationSavedState?
    var webLoadProgress: Double = 0
    var isLoading: Bool = false

    // Live web browser navigation state (driven by KVO on WKWebView)
    var currentURL: URL?
    var pageTitle: String?
    var canGoBack: Bool = false
    var canGoForward: Bool = false

    /// Heading outline extracted from the live web page's DOM, shown in the
    /// left sidebar for `.link` tabs. Rebuilt on each navigation finish.
    var tableOfContents: [WebHeading] = []

    /// A captured login awaiting the user's decision to save it. Drives the
    /// save-password banner in BrowserChromeView.
    var pendingPasswordSave: PendingPasswordSave?
    var errorMessage: String?
    var showError: Bool = false

    // Selection state for AI chat integration
    var selectedText: String?

    func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

struct PendingPasswordSave: Equatable {
    let host: String
    let username: String
    let password: String
}

struct PresentationSavedState {
    let isSidebarVisible: Bool
    let rightPanelMode: RightPanelMode?
    let isZenMode: Bool
    let displayMode: PDFDisplayMode
    let editorMode: EditorMode
    let wasAlreadyFullScreen: Bool
}
