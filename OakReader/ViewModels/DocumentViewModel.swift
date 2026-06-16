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
    /// When set, the viewer loads this URL directly instead of local HTML (used for `.link` embeds).
    var liveURL: URL?
    /// True while this tab is showing the blank new-tab router omnibox (before a
    /// destination is picked). Cleared when the tab navigates in place.
    var isNewTab: Bool = false
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

    /// Renders DB-backed text-markup highlights as an overlay (not baked into
    /// the PDF). Set as `pdfDocument.delegate` at read time. See PDFMarkupOverlay.
    let markupOverlay = PDFMarkupOverlayController()

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

    private var _studio: StudioViewModel?
    /// Per-item AI Studio: generated artifacts (quiz, mind map, deck, audio).
    var studio: StudioViewModel {
        if let vm = _studio { return vm }
        let vm = StudioViewModel(parent: self)
        _studio = vm
        return vm
    }

    /// When set, a wide Studio artifact (mind map / deck) is shown full-screen
    /// over the document. Cleared to dismiss.
    var studioFullScreenArtifact: StudioArtifact?

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
        case .link: return 1
        case .markdown: return 1
        case .audio: return 1
        }
    }

    var hasDocument: Bool {
        switch contentType {
        case .pdf: return pdfDocument != nil
        case .html: return html != nil
        case .link: return mediaDocument != nil || liveURL != nil
        case .markdown: return markdownDocument != nil
        case .audio: return false
        }
    }

    var fileName: String {
        switch contentType {
        case .pdf:
            return document?.fileURL?.lastPathComponent ?? "Untitled"
        case .html:
            return html?.htmlURL.deletingPathExtension().lastPathComponent ?? "Untitled"
        case .link:
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

    /// When this snapshot was captured — drives the snapshot toolbar's archive
    /// badge ("Snapshot · Saved Jun 3"). Bare file opens with no library item
    /// fall back to `nil` (badge shows without a date).
    var captureDate: Date? { libraryItem?.dateAdded }

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

    init(media: MediaDocument) {
        self.mediaDocument = media
        self.contentType = .link
        self.state = DocumentState()
        state.isSidebarVisible = false
    }

    init(markdown: MarkdownDocument) {
        self.markdownDocument = markdown
        self.contentType = .markdown
        self.state = DocumentState()
        state.isSidebarVisible = true
    }

    /// A transient live web page (no `MediaDocument`/library item). The `.link`
    /// content path renders `liveURL` directly in the web viewer.
    init(liveURL: URL) {
        self.contentType = .link
        self.liveURL = liveURL
        self.state = DocumentState()
        state.isSidebarVisible = false
    }

    /// A blank new-tab page (Dia-style router omnibox). `contentType` is `.link`
    /// so navigating in place (setting `liveURL`) turns it into a live web page.
    init(newTabPlaceholder: Bool) {
        self.contentType = .link
        self.isNewTab = true
        self.state = DocumentState()
        state.isSidebarVisible = false
    }

    // MARK: - Action Handling (called directly by AppState)

    func handleAction(_ action: DocumentAction) {
        // During presentation mode, only allow presentation toggle and page navigation
        if state.isPresentationMode {
            switch action {
            case .togglePresentationMode:
                break // fall through to main switch
            case .previousPage, .nextPage, .firstPage, .lastPage:
                break // allow page navigation
            default:
                return // block everything else
            }
        }

        switch action {
        case .togglePresentationMode:
            if state.isPresentationMode {
                exitPresentationMode()
            } else {
                enterPresentationMode()
            }
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

        // Selection instruments — the active view's coordinator resolves the
        // current selection (PDFSelection / DOM range) and applies via the
        // same code path as the popup, so all three handles (popup / toolbar /
        // keyboard) land at one instrument.
        case .highlightSelection:
            NotificationCenter.default.post(name: .selectionApplyHighlight, object: self)
        case .underlineSelection:
            NotificationCenter.default.post(name: .selectionApplyUnderline, object: self)
        case .attachSelectionToChat:
            NotificationCenter.default.post(name: .selectionAttachToChat, object: self)
        case .translateSelection:
            NotificationCenter.default.post(name: .selectionTranslate, object: self)
        case .askAISelection:
            NotificationCenter.default.post(name: .selectionAskAI, object: self)

        case .exitAnnotateMode:
            if state.editorMode != .viewer {
                annotation.currentTool = .none
                setEditorMode(.viewer)
            }
        }
    }

    // MARK: - Presentation Mode

    func enterPresentationMode() {
        guard contentType == .pdf, pdfDocument != nil else { return }

        let window = NSApp.keyWindow
        let wasFullScreen = window?.styleMask.contains(.fullScreen) ?? false

        state.presentationSavedState = PresentationSavedState(
            isSidebarVisible: state.isSidebarVisible,
            rightPanelMode: state.rightPanelMode,
            isZenMode: state.isZenMode,
            displayMode: state.displayMode,
            editorMode: state.editorMode,
            wasAlreadyFullScreen: wasFullScreen
        )

        state.isSidebarVisible = false
        state.rightPanelMode = nil
        state.isZenMode = false
        state.editorMode = .viewer
        state.displayMode = .singlePage
        state.isPresentationMode = true

        if !wasFullScreen {
            window?.toggleFullScreen(nil)
        }
    }

    func exitPresentationMode() {
        state.isPresentationMode = false

        if let saved = state.presentationSavedState {
            state.isSidebarVisible = saved.isSidebarVisible
            state.rightPanelMode = saved.rightPanelMode
            state.isZenMode = saved.isZenMode
            state.displayMode = saved.displayMode
            state.editorMode = saved.editorMode

            if !saved.wasAlreadyFullScreen {
                let window = NSApp.keyWindow
                if window?.styleMask.contains(.fullScreen) == true {
                    window?.toggleFullScreen(nil)
                }
            }

            state.presentationSavedState = nil
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

    /// Coalesces a burst of edits (e.g. several highlights in a row) into a single
    /// near-immediate autosave so the PDF on disk — and the tab's "unsaved" dot —
    /// catches up within ~1s instead of waiting for the 30s autosave tick.
    private var autosaveDebounce: Timer?

    func markDocumentEdited() {
        document?.updateChangeCount(.changeDone)

        autosaveDebounce?.invalidate()
        autosaveDebounce = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let document = self?.document,
                  document.hasUnautosavedChanges || document.isDocumentEdited else { return }
            document.autosave(withImplicitCancellability: true) { _ in }
        }
    }

    func setEditorMode(_ mode: EditorMode) {
        // Leaving snapshot mode always clears the "route to chat" intent so a
        // later menu/shortcut capture falls back to the annotation popup.
        if mode != .snapshot { state.snapshotForChat = false }
        state.editorMode = mode
    }

    /// Begin a Dia-style region capture whose result is attached straight to the
    /// AI chat composer. Triggered by the chat input's screenshot button: makes
    /// sure chat is visible, then arms the crosshair overlay.
    func beginAreaCaptureForChat() {
        Log.debug(Log.ui, "[capture-cursor] beginAreaCaptureForChat — contentType: \(contentType)")
        state.snapshotForChat = true
        state.rightPanelMode = .aiChat
        state.editorMode = .snapshot
    }

    /// Deliver a finished area capture into the chat composer and leave snapshot
    /// mode. Used by the overlays when the capture was initiated for chat.
    func deliverAreaCaptureToChat(_ pngData: Data, pageIndex: Int) {
        chat.addImageAttachment(pngData, pageIndex: pageIndex)
        state.rightPanelMode = .aiChat
        setEditorMode(.viewer)
    }
}
