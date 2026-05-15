import Foundation
import PDFKit
import AppKit
import Combine
import OakAgent

@Observable
class DocumentViewModel {
    weak var document: OakReaderDocument?
    var html: HTMLDocument?
    var mediaDocument: MediaDocument?
    var markdownDocument: MarkdownDocument?
    /// Observable markdown content for reactive outline updates.
    var markdownContent: String = ""
    var contentType: ContentType
    var state: DocumentState
    /// Database reference, set by AppState when the tab is created.
    var database: CatalogDatabase?
    /// Reference service, set by AppState when the tab is created.
    var referenceService: ReferenceService?
    /// Library store, set by AppState when the tab is created.
    var libraryStore: LibraryStore?
    /// App state reference for navigation, set when the tab is created.
    weak var appState: AppState?

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
        if let db = database {
            vm.sessionService = ConversationService(database: db)
        }
        if let item = libraryItem {
            vm.itemId = item.id.uuidString
        }
        _chat = vm
        return vm
    }

    private var _notes: NotesViewModel?
    var notes: NotesViewModel {
        if let vm = _notes { return vm }
        let vm = NotesViewModel(parent: self, database: database, storageKey: storageKey)
        _notes = vm
        return vm
    }

    private var _voice: VoiceViewModel?
    var voice: VoiceViewModel {
        if let vm = _voice { return vm }
        let vm = VoiceViewModel()
        _voice = vm
        return vm
    }

    private var _translation: TranslationViewModel?
    var translation: TranslationViewModel {
        if let vm = _translation { return vm }
        let vm = TranslationViewModel(parent: self)
        _translation = vm
        return vm
    }

    private var _media: MediaViewModel?
    var media: MediaViewModel {
        if let vm = _media { return vm }
        let vm = MediaViewModel(parent: self)
        _media = vm
        return vm
    }

    /// The item-level storage key, set externally by AppState when creating the tab.
    var itemStorageKey: String?

    /// The primary attachment ID, set externally by AppState when creating the tab.
    var attachmentId: String?

    /// The storage key for this document's item directory.
    var storageKey: String? {
        itemStorageKey
    }

    /// Returns the document's item-level storage directory.
    private var documentStoragePath: URL? {
        guard let key = itemStorageKey else { return nil }
        return CatalogDatabase.documentDirectory(storageKey: key)
    }

    // MARK: - Computed Properties

    var pdfDocument: PDFDocument? {
        document?.pdfDocument
    }

    var pageCount: Int {
        switch contentType {
        case .pdf: return pdfDocument?.pageCount ?? 0
        case .html: return 1
        case .video: return 1
        case .markdown: return 1
        case .audio: return 1
        }
    }

    var hasDocument: Bool {
        switch contentType {
        case .pdf: return pdfDocument != nil
        case .html: return html != nil
        case .video: return mediaDocument != nil
        case .markdown: return markdownDocument != nil
        case .audio: return false
        }
    }

    var usesMediaSidebar: Bool {
        contentType == .video && mediaDocument?.metadata.resolvedEmbedType == .youtube
    }

    var fileName: String {
        switch contentType {
        case .pdf:
            return document?.fileURL?.lastPathComponent ?? "Untitled"
        case .html:
            return html?.htmlURL.deletingPathExtension().lastPathComponent ?? "Untitled"
        case .video:
            return mediaDocument?.metadata.title ?? "Untitled"
        case .markdown:
            return markdownDocument?.fileURL.deletingPathExtension().lastPathComponent ?? "Untitled"
        case .audio:
            return "Untitled"
        }
    }

    /// The library item for this document, looked up by storage key.
    var libraryItem: LibraryItem? {
        guard let key = storageKey else { return nil }
        return libraryStore?.findItem(byStorageKey: key)
    }

    /// The library item's ID as a string, for annotation persistence.
    var itemId: String? { libraryItem?.id.uuidString }

    // MARK: - Initialization

    init(document: OakReaderDocument) {
        self.document = document
        self.contentType = .pdf
        self.state = DocumentState()

        let prefs = Preferences.shared
        state.zoomLevel = prefs.defaultZoomLevel
        state.displayMode = prefs.displayMode
        state.isSidebarVisible = prefs.showSidebar
        state.sidebarMode = prefs.sidebarMode
    }

    init(html: HTMLDocument) {
        self.html = html
        self.contentType = .html
        self.state = DocumentState()

        let prefs = Preferences.shared
        state.isSidebarVisible = false
    }

    /// Last playback time (seconds) for embed videos, preserved across tab switches.
    var lastPlaybackTime: Double?

    init(media: MediaDocument) {
        self.mediaDocument = media
        self.contentType = .video
        self.state = DocumentState()
        state.isSidebarVisible = media.metadata.resolvedEmbedType == .youtube
        state.mediaSidebarMode = .outline
    }

    init(markdown: MarkdownDocument) {
        self.markdownDocument = markdown
        self.contentType = .markdown
        self.state = DocumentState()
        state.isSidebarVisible = true
    }

    // MARK: - Action Handling (called directly by AppState)

    func handleAction(_ action: DocumentAction) {
        switch action {
        case .toggleZenMode:
            state.isZenMode.toggle()
            if state.isZenMode {
                state.isSidebarVisible = false
                state.rightPanelMode = nil
            }
        case .toggleSidebar:
            guard !state.isZenMode else { return }
            state.isSidebarVisible.toggle()
        case .toggleInspector:
            guard !state.isZenMode else { return }
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
            if usesMediaSidebar {
                state.mediaSidebarMode = .transcript
            } else {
                state.sidebarMode = .search
            }
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
