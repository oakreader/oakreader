import Foundation
import PDFKit
import AppKit
import Combine
import OakReaderAI

@Observable
class DocumentViewModel {
    weak var document: OakReaderDocument?
    var webSnapshot: WebSnapshotDocument?
    var mediaDocument: MediaDocument?
    var documentType: DocumentType
    var state: DocumentState

    // MARK: - Child ViewModels (lazy)

    private var _viewer: ViewerViewModel?
    var viewer: ViewerViewModel {
        if let vm = _viewer { return vm }
        let vm = ViewerViewModel(parent: self)
        _viewer = vm
        return vm
    }

    private var _annotation: AnnotationViewModel?
    var annotation: AnnotationViewModel {
        if let vm = _annotation { return vm }
        let vm = AnnotationViewModel(parent: self)
        _annotation = vm
        return vm
    }

    private var _accessibility: AccessibilityViewModel?
    var accessibility: AccessibilityViewModel {
        if let vm = _accessibility { return vm }
        let vm = AccessibilityViewModel(parent: self)
        _accessibility = vm
        return vm
    }

    private var _convert: ConvertViewModel?
    var convert: ConvertViewModel {
        if let vm = _convert { return vm }
        let vm = ConvertViewModel(parent: self)
        _convert = vm
        return vm
    }

    private var _security: SecurityViewModel?
    var security: SecurityViewModel {
        if let vm = _security { return vm }
        let vm = SecurityViewModel(parent: self)
        _security = vm
        return vm
    }

    private var _chat: ChatViewModel?
    var chat: ChatViewModel {
        if let vm = _chat { return vm }
        // Derive document storage path from file URL if it's in managed storage
        let storagePath = documentStoragePath
        let vm = ChatViewModel(parent: self, documentStoragePath: storagePath)
        _chat = vm
        return vm
    }

    /// Returns the document's managed storage directory if the file is in ~/OakReader/storage/.
    private var documentStoragePath: URL? {
        switch documentType {
        case .pdf:
            guard let fileURL = document?.fileURL else { return nil }
            let storageDirPath = CatalogDatabase.storageDirectory.path
            guard fileURL.path.hasPrefix(storageDirPath) else { return nil }
            return fileURL.deletingLastPathComponent()
        case .webSnapshot:
            guard let fileURL = webSnapshot?.htmlURL else { return nil }
            let storageDirPath = CatalogDatabase.storageDirectory.path
            guard fileURL.path.hasPrefix(storageDirPath) else { return nil }
            return fileURL.deletingLastPathComponent()
        case .youtubeVideo, .podcast:
            return mediaDocument?.storageDirectory
        }
    }

    // MARK: - Computed Properties

    var pdfDocument: PDFDocument? {
        document?.pdfDocument
    }

    var pageCount: Int {
        switch documentType {
        case .pdf: return pdfDocument?.pageCount ?? 0
        case .webSnapshot: return 1
        case .youtubeVideo, .podcast: return 1
        }
    }

    var hasDocument: Bool {
        switch documentType {
        case .pdf: return pdfDocument != nil
        case .webSnapshot: return webSnapshot != nil
        case .youtubeVideo, .podcast: return mediaDocument != nil
        }
    }

    var fileName: String {
        switch documentType {
        case .pdf:
            return document?.fileURL?.lastPathComponent ?? "Untitled"
        case .webSnapshot:
            return webSnapshot?.htmlURL.deletingPathExtension().lastPathComponent ?? "Untitled"
        case .youtubeVideo, .podcast:
            return mediaDocument?.metadata.title ?? "Untitled"
        }
    }

    // MARK: - Initialization

    init(document: OakReaderDocument) {
        self.document = document
        self.documentType = .pdf
        self.state = DocumentState()

        let prefs = Preferences.shared
        state.zoomLevel = prefs.defaultZoomLevel
        state.displayMode = prefs.displayMode
        state.isSidebarVisible = prefs.showSidebar
        state.sidebarMode = prefs.sidebarMode
    }

    init(webSnapshot: WebSnapshotDocument) {
        self.webSnapshot = webSnapshot
        self.documentType = .webSnapshot
        self.state = DocumentState()

        let prefs = Preferences.shared
        state.isSidebarVisible = false
    }

    init(media: MediaDocument) {
        self.mediaDocument = media
        self.documentType = media.audioURL != nil ? .podcast : .youtubeVideo
        self.state = DocumentState()
        state.isSidebarVisible = false
    }

    // MARK: - Action Handling (called directly by AppState)

    func handleAction(_ action: DocumentAction) {
        switch action {
        case .toggleSidebar:
            state.isSidebarVisible.toggle()
        case .toggleInspector:
            if state.rightPanelMode != nil {
                state.rightPanelMode = nil
            } else {
                state.rightPanelMode = .aiChat
            }
        case .zoomIn:
            viewer.zoomIn()
        case .zoomOut:
            viewer.zoomOut()
        case .zoomToFit:
            viewer.zoomToFit()
        case .displaySingle:
            viewer.setDisplayMode(.singlePage)
        case .displaySingleContinuous:
            viewer.setDisplayMode(.singlePageContinuous)
        case .displayTwoUp:
            viewer.setDisplayMode(.twoUp)
        case .displayTwoUpContinuous:
            viewer.setDisplayMode(.twoUpContinuous)
        case .find:
            state.sidebarMode = .search
            state.isSidebarVisible = true
        case .accessibilityCheck:
            Task { @MainActor in
                await accessibility.runCheck()
            }
        case .rotateRight:
            rotatePage(by: 90)
        case .rotateLeft:
            rotatePage(by: -90)
        case .exportImages:
            break // Handled by Export sheet in the UI
        case .snapshot:
            state.editorMode = .snapshot
        case .navigateBack:
            viewer.goBack()
        case .previousPage:
            viewer.goToPage(state.currentPageIndex - 1)
        case .nextPage:
            viewer.goToPage(state.currentPageIndex + 1)
        case .firstPage:
            viewer.goToPage(0)
        case .lastPage:
            viewer.goToPage(pageCount - 1)
        }
    }

    // MARK: - Page Rotation

    func rotatePage(by degrees: Int) {
        guard let pdfDoc = pdfDocument,
              state.currentPageIndex < pdfDoc.pageCount,
              let page = pdfDoc.page(at: state.currentPageIndex) else { return }
        page.rotation += degrees
        markDocumentEdited()
    }

    // MARK: - Document Mutation

    func markDocumentEdited() {
        document?.updateChangeCount(.changeDone)
    }

    func setEditorMode(_ mode: EditorMode) {
        state.editorMode = mode
    }
}
