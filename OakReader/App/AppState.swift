import Foundation
import PDFKit
import AppKit
import OakVoice

// MARK: - Tab Content

enum TabContent {
    case pdf(OakReaderDocument)
    case html(HTMLDocument)
    case media(MediaDocument)
    case markdown(MarkdownDocument)
    /// A transient live web page opened from the new-tab router (no library item).
    case web(URL)
    /// A blank new-tab page showing the Dia-style router omnibox. Becomes `.web`
    /// once the user picks a destination (navigated in place).
    case newTab
}

// MARK: - Document Tab

@Observable
final class DocumentTab: Identifiable {
    let id: UUID
    /// Mutable so a `.newTab` page can navigate in place into `.web` once a
    /// destination is chosen, keeping share/command context accurate.
    var content: TabContent
    let viewModel: DocumentViewModel
    var title: String
    /// Storage key for this document's managed directory (nil for unsaved/blank documents).
    let storageKey: String?

    /// The PDF document, if this tab holds one.
    var document: OakReaderDocument? {
        if case .pdf(let doc) = content { return doc }
        return nil
    }

    /// The title shown in the tab bar. For live web tabs this tracks the page's
    /// `<title>` (and falls back to the current host) so it stays current across
    /// in-place navigation; other tab kinds use their stored `title`. Reading the
    /// `@Observable` web state here means the tab bar re-renders automatically as
    /// the page loads — no manual syncing back into `title`.
    var displayTitle: String {
        switch content {
        case .web, .newTab:
            let state = viewModel.state
            if let pageTitle = state.pageTitle, !pageTitle.isEmpty {
                return pageTitle
            }
            if let host = (state.currentURL ?? viewModel.liveURL)?.host {
                return host
            }
            return title
        default:
            return title
        }
    }

    var isDirty: Bool {
        guard let document else { return false }
        return document.hasUnautosavedChanges || document.isDocumentEdited
    }

    init(document: OakReaderDocument, storageKey: String? = nil) {
        self.id = UUID()
        self.content = .pdf(document)
        self.viewModel = document.documentViewModel
        self.title = document.fileURL?.lastPathComponent ?? "Untitled"
        self.storageKey = storageKey
    }

    init(html: HTMLDocument, storageKey: String? = nil) {
        self.id = UUID()
        self.content = .html(html)
        self.viewModel = DocumentViewModel(html: html)
        self.title = html.htmlURL.deletingPathExtension().lastPathComponent
        self.storageKey = storageKey
    }

    init(media: MediaDocument, storageKey: String? = nil) {
        self.id = UUID()
        self.content = .media(media)
        self.viewModel = DocumentViewModel(media: media)
        self.title = media.metadata.title
        self.storageKey = storageKey
    }

    init(markdown: MarkdownDocument, storageKey: String? = nil) {
        self.id = UUID()
        self.content = .markdown(markdown)
        self.viewModel = DocumentViewModel(markdown: markdown)
        self.title = markdown.fileURL.deletingPathExtension().lastPathComponent
        self.storageKey = storageKey
    }

    /// A transient live web tab opened from the new-tab router. Holds only a URL —
    /// nothing is persisted to the library.
    init(webURL: URL) {
        self.id = UUID()
        self.content = .web(webURL)
        self.viewModel = DocumentViewModel(liveURL: webURL)
        self.title = webURL.host ?? webURL.absoluteString
        self.storageKey = nil
    }

    /// A blank new-tab page (Dia-style router omnibox).
    init(newTab: Bool) {
        self.id = UUID()
        self.content = .newTab
        self.viewModel = DocumentViewModel(newTabPlaceholder: true)
        self.title = "New Tab"
        self.storageKey = nil
    }

}

// MARK: - Library Surface

/// Which full-window surface the library shows when no document tab is active.
enum LibrarySurface {
    /// The classic 3-pane catalog browser (sidebar · table · detail panel).
    case browse
    /// The full-page Dia-style AI agent workspace.
    case agent
}

// MARK: - App State

@Observable
final class AppState {
    let libraryStore: LibraryStore
    let coverService = LibraryCoverService()
    let referenceService: ReferenceService
    let importService: ImportService
    var ftsIndexService: FTSIndexService?
    private var backgroundIndexTask: Task<Void, Never>?

    var openTabs: [DocumentTab] = []
    var activeTabID: UUID?
    var window: NSWindow?
    var selectedLibraryItemIDs: Set<UUID> = []
    var showSettings: Bool = false
    var showZoteroImport: Bool = false
    var zoteroImportDataDir: URL?
    var showBackupExport: Bool = false
    var backupExportURL: URL?
    var showBackupRestore: Bool = false
    var backupRestoreURL: URL?
    var isLibrarySidebarVisible: Bool = true
    var libraryDetailTab: LibraryDetailTab?
    /// Which surface the library window shows (catalog browser vs. AI agent workspace).
    var librarySurface: LibrarySurface = .browse
    /// Whether the Agent tab exists in the title bar (shown until closed).
    var isAgentTabOpen: Bool = false
    /// When set, the agent workspace is bound to this item (overrides collection scope).
    var agentBoundItemStorageKey: String?
    /// The resolved on-disk workspace folder for the active agent binding.
    var agentWorkspaceDirectory: URL?
    var importNotification: String?

    // MARK: - Library Chat

    private var _libraryChatVM: ChatViewModel?
    var libraryChatVM: ChatViewModel {
        if let vm = _libraryChatVM { return vm }
        let vm = ChatViewModel()
        vm.appState = self
        vm.itemId = "library"
        vm.sessionService = ConversationService(database: libraryStore.database)
        _libraryChatVM = vm
        return vm
    }

    private var autosaveTimer: Timer?

    var isLibraryActive: Bool {
        activeTabID == nil
    }

    /// The library catalog browser is the active surface.
    var isLibraryBrowseActive: Bool {
        activeTabID == nil && librarySurface == .browse
    }

    /// The full-page AI agent workspace is the active surface.
    var isAgentActive: Bool {
        activeTabID == nil && librarySurface == .agent
    }

    var activeTab: DocumentTab? {
        guard let id = activeTabID else { return nil }
        return openTabs.first { $0.id == id }
    }

    var selectedLibraryItem: LibraryItem? {
        guard let firstID = selectedLibraryItemIDs.first else { return nil }
        return libraryStore.findItem(byId: firstID)
    }

    init() {
        let database: CatalogDatabase
        do {
            database = try CatalogDatabase()
        } catch {
            fatalError("[AppState] Failed to initialize database: \(error)")
        }
        self.libraryStore = LibraryStore(database: database)
        self.referenceService = ReferenceService(database: database)
        self.importService = ImportService(store: libraryStore, coverService: coverService, referenceService: referenceService)
        startAutosaveTimer()

        // Initialize the full-text index service asynchronously
        startContentIndexing(database: database)

        // Listen for rebuild requests from settings
        NotificationCenter.default.addObserver(
            forName: .searchIndexRebuildRequested,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.backgroundIndexTask?.cancel()
            self.startContentIndexing(database: self.libraryStore.database)
        }
    }

    private func startContentIndexing(database: CatalogDatabase) {
        backgroundIndexTask = Task {
            do {
                let ftsDB = try FTSDatabase()
                let service = FTSIndexService.create(
                    ftsDB: ftsDB,
                    catalogDBQueue: database.dbQueue
                )
                await MainActor.run {
                    self.ftsIndexService = service
                    self.importService.ftsIndexService = service
                    self.libraryStore.ftsIndexService = service
                }
                Log.info(Log.fts, "Full-text index service initialized")
                await service.backgroundIndexAll()
                // Lower-priority second pass: OCR the image-only PDFs left empty above.
                await service.backgroundOCRBackfill()
            } catch {
                Log.error(Log.fts, "Failed to initialize full-text index service: \(error)")
            }
        }
    }

    // MARK: - Tab Operations

    /// Open a document from a URL. Dispatches to PDF, HTML, or markdown based on file extension.
    func openDocument(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            Analytics.capture("document_opened", properties: ["type": "html"])
            openHTMLDocument(url: url)
            return
        }
        if ext == "md" || ext == "markdown" {
            Analytics.capture("document_opened", properties: ["type": "markdown"])
            openExternalMarkdown(url: url)
            return
        }
        // Check if already open by URL
        if let existing = openTabs.first(where: { $0.document?.fileURL == url }) {
            switchToTab(existing.id)
            return
        }

        // Import into managed storage (or find existing)
        let item = importService.importPDF(from: url)
        let pdfURL = item?.fileURL ?? url
        let storageKey = item?.storageKey

        // Check if the managed URL is already open
        if let item, let existing = openTabs.first(where: { $0.document?.fileURL == item.fileURL }) {
            switchToTab(existing.id)
            return
        }

        let doc = OakReaderDocument()
        do {
            Log.info(Log.open, "Reading PDF from: \(pdfURL.path)")
            try doc.read(from: pdfURL, ofType: "com.adobe.pdf")
            doc.fileURL = pdfURL
            Log.info(Log.open, "Successfully read PDF: \(pdfURL.lastPathComponent)")
        } catch {
            Log.error(Log.open, "Failed to read PDF: \(pdfURL.lastPathComponent) — \(error)")
            NSAlert(error: error).runModal()
            return
        }

        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        Analytics.capture("document_opened", properties: ["type": "pdf"])

        if let item {
            libraryStore.markOpened(item)
        }

        let tab = DocumentTab(document: doc, storageKey: storageKey)
        tab.viewModel.database = libraryStore.database
        tab.viewModel.referenceService = referenceService
        tab.viewModel.libraryStore = libraryStore
        tab.viewModel.appState = self
        tab.viewModel.itemStorageKey = storageKey
        tab.viewModel.attachmentId = item?.primaryAttachment?.id.uuidString

        // Use original filename (not "document.pdf" from managed storage)
        tab.title = item?.fileName ?? url.lastPathComponent
        NSDocumentController.shared.addDocument(doc)
        openTabs.append(tab)
        activeTabID = tab.id
        updateWindowTitle()
    }

    /// Open a markdown file at its original path without importing to library.
    func openExternalMarkdown(url: URL) {
        // Dedup: check if already open by fileURL
        if let existing = openTabs.first(where: {
            if case .markdown(let doc) = $0.content { return doc.fileURL == url }
            return false
        }) {
            switchToTab(existing.id)
            return
        }

        do {
            let mdDoc = try MarkdownDocument(fileURL: url)
            let tab = DocumentTab(markdown: mdDoc, storageKey: nil)
            tab.viewModel.appState = self

            tab.title = url.deletingPathExtension().lastPathComponent
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            openTabs.append(tab)
            activeTabID = tab.id
            updateWindowTitle()
        } catch {
            Log.error(Log.open, "Failed to open markdown: \(url.lastPathComponent) — \(error)")
            NSAlert(error: error).runModal()
        }
    }

    /// Open an arbitrary URL as a transient live web tab (from the new-tab router).
    /// Nothing is imported into the library; the page loads directly in the web viewer.
    func openWebTab(url: URL) {
        let tab = DocumentTab(webURL: url)
        tab.viewModel.database = libraryStore.database
        tab.viewModel.referenceService = referenceService
        tab.viewModel.libraryStore = libraryStore
        tab.viewModel.appState = self
        openTabs.append(tab)
        activeTabID = tab.id
        updateWindowTitle()
    }

    /// Open an HTML document.
    private func openHTMLDocument(url: URL) {
        let item = importService.importHTML(from: url)
        let htmlURL = item?.fileURL ?? url
        let storageKey = item?.storageKey

        do {
            let snapshot = try HTMLDocument(htmlURL: htmlURL, sourceURL: item?.sourceURL)
            let tab = DocumentTab(html: snapshot, storageKey: storageKey)
            tab.viewModel.database = libraryStore.database
            tab.viewModel.referenceService = referenceService
            tab.viewModel.libraryStore = libraryStore
            tab.viewModel.appState = self
            tab.viewModel.itemStorageKey = storageKey
            tab.viewModel.attachmentId = item?.primaryAttachment?.id.uuidString

            tab.title = item?.title ?? url.deletingPathExtension().lastPathComponent
            openTabs.append(tab)
            activeTabID = tab.id
            updateWindowTitle()

            if let item {
                libraryStore.markOpened(item)
            }
        } catch {
            Log.error(Log.open, "Failed to open HTML: \(url.lastPathComponent) — \(error)")
            NSAlert(error: error).runModal()
        }
    }

    /// Open a library item directly (already imported). Dispatches by document type.
    func openLibraryItem(_ item: LibraryItem) {
        // Mark opened up front so re-opening an already-open item still refreshes
        // last_opened_at (the per-type open funcs return early when a tab exists).
        libraryStore.markOpened(item)
        if item.contentType != .audio {
            Analytics.capture("document_opened", properties: ["type": "\(item.contentType)"])
        }
        switch item.contentType {
        case .html:
            openHTMLItem(item)
        case .pdf:
            openPDFItem(item)
        case .link:
            openMediaItem(item)
        case .markdown:
            openMarkdownItem(item)
        case .audio:
            break // Audio items are played in-library; no separate document tab
        }
    }

    private func openPDFItem(_ item: LibraryItem) {
        let pdfURL = item.fileURL

        // Check if already open
        if let existing = openTabs.first(where: { $0.document?.fileURL == pdfURL }) {
            switchToTab(existing.id)
            return
        }

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            let primaryKey = item.primaryAttachment?.storageKey ?? "nil"
            Log.error(
                Log.open,
                "Cannot open PDF \"\(item.title)\": file not found at \(pdfURL.path) "
                    + "(primaryAttachment=\(primaryKey), attachments=\(item.attachments.count))"
            )
            let alert = NSAlert()
            alert.messageText = "Cannot Open PDF"
            alert.informativeText = "The file \"\(item.title)\" could not be found in managed storage."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let doc = OakReaderDocument()
        do {
            try doc.read(from: pdfURL, ofType: "com.adobe.pdf")
            doc.fileURL = pdfURL
        } catch {
            Log.error(Log.open, "Failed to read PDF: \(item.title) — \(error)")
            NSAlert(error: error).runModal()
            return
        }

        NSDocumentController.shared.noteNewRecentDocumentURL(pdfURL)

        let tab = DocumentTab(document: doc, storageKey: item.storageKey)
        tab.viewModel.database = libraryStore.database
        tab.viewModel.referenceService = referenceService
        tab.viewModel.libraryStore = libraryStore
        tab.viewModel.appState = self
        tab.viewModel.itemStorageKey = item.storageKey
        tab.viewModel.attachmentId = item.primaryAttachment?.id.uuidString

        // Use original filename from library item
        tab.title = item.fileName
        NSDocumentController.shared.addDocument(doc)
        openTabs.append(tab)
        activeTabID = tab.id
        updateWindowTitle()
    }

    private func openHTMLItem(_ item: LibraryItem) {
        let htmlURL = item.fileURL
        // Check if already open by storage key
        if let existing = openTabs.first(where: { $0.storageKey == item.storageKey }) {
            switchToTab(existing.id)
            return
        }

        guard FileManager.default.fileExists(atPath: htmlURL.path) else {
            let alert = NSAlert()
            alert.messageText = "Cannot Open Web Page"
            alert.informativeText = "The file \"\(item.title)\" could not be found in managed storage."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        do {
            let snapshot = try HTMLDocument(htmlURL: htmlURL, sourceURL: item.sourceURL)

            let tab = DocumentTab(html: snapshot, storageKey: item.storageKey)
            tab.viewModel.database = libraryStore.database
            tab.viewModel.referenceService = referenceService
            tab.viewModel.libraryStore = libraryStore
            tab.viewModel.appState = self
            tab.viewModel.itemStorageKey = item.storageKey
            tab.viewModel.attachmentId = item.primaryAttachment?.id.uuidString

            tab.title = item.title
            openTabs.append(tab)
            activeTabID = tab.id
            updateWindowTitle()
        } catch {
            Log.error(Log.open, "Failed to open HTML document: \(item.title) — \(error)")
            NSAlert(error: error).runModal()
        }
    }

    private func openMediaItem(_ item: LibraryItem) {
        // Check if already open by storage key
        if let existing = openTabs.first(where: { $0.storageKey == item.storageKey }) {
            switchToTab(existing.id)
            return
        }

        guard let primary = item.primaryAttachment else { return }
        let attDir = primary.documentDirectory
        let metadataURL = primary.fileURL

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            let alert = NSAlert()
            alert.messageText = "Cannot Open \(item.contentType.label)"
            alert.informativeText = "The metadata for \"\(item.title)\" could not be found."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        do {
            let media = try MediaDocument(storageDirectory: attDir)

            let tab = DocumentTab(media: media, storageKey: item.storageKey)
            tab.viewModel.database = libraryStore.database
            tab.viewModel.referenceService = referenceService
            tab.viewModel.libraryStore = libraryStore
            tab.viewModel.appState = self
            tab.viewModel.itemStorageKey = item.storageKey
            tab.viewModel.attachmentId = item.primaryAttachment?.id.uuidString

            if media.metadata.resolvedEmbedType == .link {
                tab.viewModel.liveURL = media.sourceURL
            }

            tab.title = item.title
            openTabs.append(tab)
            activeTabID = tab.id
            updateWindowTitle()
        } catch {
            Log.error(Log.open, "Failed to open media item: \(item.title) — \(error)")
            NSAlert(error: error).runModal()
        }
    }

    private func openMarkdownItem(_ item: LibraryItem) {
        // Check if already open by storage key
        if let existing = openTabs.first(where: { $0.storageKey == item.storageKey }) {
            switchToTab(existing.id)
            return
        }

        let mdURL = item.fileURL
        guard FileManager.default.fileExists(atPath: mdURL.path) else {
            let alert = NSAlert()
            alert.messageText = "Cannot Open Markdown"
            alert.informativeText = "The file \"\(item.title)\" could not be found in managed storage."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        do {
            let mdDoc = try MarkdownDocument(fileURL: mdURL)

            let tab = DocumentTab(markdown: mdDoc, storageKey: item.storageKey)
            tab.viewModel.database = libraryStore.database
            tab.viewModel.referenceService = referenceService
            tab.viewModel.libraryStore = libraryStore
            tab.viewModel.appState = self
            tab.viewModel.itemStorageKey = item.storageKey
            tab.viewModel.attachmentId = item.primaryAttachment?.id.uuidString

            tab.title = item.title
            openTabs.append(tab)
            activeTabID = tab.id
            updateWindowTitle()
        } catch {
            Log.error(Log.open, "Failed to open markdown: \(item.title) — \(error)")
            NSAlert(error: error).runModal()
        }
    }

    func closeTab(_ tabID: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = openTabs[index]

        // Check for unsaved changes (PDF only)
        if tab.isDirty, let doc = tab.document {
            let alert = NSAlert()
            alert.messageText = "Do you want to save changes to \"\(tab.title)\"?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                doc.save(nil)
            case .alertThirdButtonReturn:
                return // Cancel close
            default:
                break
            }
        }

        tab.document?.close()
        openTabs.remove(at: index)

        if activeTabID == tabID {
            let allTabs = combinedTabIDs
            if allTabs.isEmpty {
                activeTabID = nil
            } else {
                activeTabID = allTabs.first
            }
        }
        updateWindowTitle()
    }

    func closeActiveTab() {
        guard let id = activeTabID else { return }
        closeTab(id)
    }

    func switchToTab(_ tabID: UUID) {
        guard openTabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
        updateWindowTitle()
    }

    func switchToLibrary() {
        activeTabID = nil
        updateWindowTitle()
    }

    /// Show the classic catalog browser surface.
    func showLibraryBrowse() {
        activeTabID = nil
        librarySurface = .browse
        updateWindowTitle()
    }

    /// Open a real new tab showing the Dia-style router omnibox (browser-style:
    /// a "New Tab" chip appears in the strip and becomes active).
    func openNewTab() {
        let tab = DocumentTab(newTab: true)
        tab.viewModel.database = libraryStore.database
        tab.viewModel.referenceService = referenceService
        tab.viewModel.libraryStore = libraryStore
        tab.viewModel.appState = self
        openTabs.append(tab)
        activeTabID = tab.id
        updateWindowTitle()
    }

    /// Execute a new-tab router decision made from the omnibox in `viewModel`'s tab.
    /// Navigate/search turn that same tab into a live web page (in place, like a
    /// browser); ask hands the text to a fresh agent chat and drops the new tab.
    @MainActor
    func routeNewTab(_ route: BrowserSession.Route, from viewModel: DocumentViewModel) {
        switch route {
        case .navigate(let url), .search(let url):
            viewModel.liveURL = url
            viewModel.isNewTab = false
            if let tab = openTabs.first(where: { $0.viewModel === viewModel }) {
                tab.content = .web(url)
                tab.title = url.host ?? url.absoluteString
            }
            updateWindowTitle()
        case .ask(let text):
            let newTabID = openTabs.first(where: { $0.viewModel === viewModel })?.id
            openAgentWorkspace(newSession: true)
            libraryChatVM.inputText = text
            libraryChatVM.send()
            if let id = newTabID { closeTab(id) }
        }
    }

    /// Show the full-page AI agent workspace. Optionally start a fresh chat session.
    func openAgentWorkspace(newSession: Bool = false) {
        activeTabID = nil
        librarySurface = .agent
        isAgentTabOpen = true
        if newSession {
            libraryChatVM.newSession()
        }
        refreshAgentWorkspace()
        updateWindowTitle()
    }

    /// Open the agent workspace bound to a specific library item, mounting its file.
    func openAgentOnItem(_ item: LibraryItem) {
        agentBoundItemStorageKey = item.storageKey
        activeTabID = nil
        librarySurface = .agent
        isAgentTabOpen = true
        refreshAgentWorkspace()
        updateWindowTitle()
    }

    /// Close the Agent tab: hide its pill and, if it's the active surface, fall
    /// back to the catalog browser. The chat session itself is kept in history.
    func closeAgentWorkspace() {
        isAgentTabOpen = false
        agentBoundItemStorageKey = nil
        if librarySurface == .agent {
            librarySurface = .browse
        }
        updateWindowTitle()
    }

    /// Resolve the current binding (bound item → selected collection → general),
    /// provision its `<dataDir>/workspace/` folder, mount sources (CoW) off the main
    /// thread, and point the library agent's file tools at it.
    func refreshAgentWorkspace() {
        let binding: AgentWorkspace.Binding
        var sources: [URL] = []
        if let key = agentBoundItemStorageKey,
           let item = libraryStore.items.first(where: { $0.storageKey == key }) {
            binding = .item(storageKey: key)
            sources = [item.fileURL]
        } else if let collection = libraryStore.selectedCollection,
                  collection.id != SystemCollectionID.allItems,
                  !collection.isSmart {
            binding = .collection(id: collection.id)
            sources = libraryStore.items
                .filter { item in item.collections.contains { $0.id == collection.id } }
                .map(\.fileURL)
        } else {
            binding = .general
        }

        let dir = AgentWorkspace.ensureDirectory(for: binding)
        agentWorkspaceDirectory = dir
        libraryChatVM.workspaceDirectory = dir
        if !sources.isEmpty {
            let mounts = sources
            Task.detached { AgentWorkspace.mountSources(mounts, into: dir) }
        }
    }

    func nextTab() {
        let allIDs = combinedTabIDs
        guard !allIDs.isEmpty, let currentID = activeTabID,
              let currentIndex = allIDs.firstIndex(of: currentID) else { return }
        let nextIndex = (currentIndex + 1) % allIDs.count
        switchToTab(allIDs[nextIndex])
    }

    func previousTab() {
        let allIDs = combinedTabIDs
        guard !allIDs.isEmpty, let currentID = activeTabID,
              let currentIndex = allIDs.firstIndex(of: currentID) else { return }
        let prevIndex = (currentIndex - 1 + allIDs.count) % allIDs.count
        switchToTab(allIDs[prevIndex])
    }

    /// All tab IDs in display order.
    private var combinedTabIDs: [UUID] {
        openTabs.map(\.id)
    }

    // MARK: - Window

    func updateWindowTitle() {
        window?.title = ""
    }

    // MARK: - Undo Manager

    var currentUndoManager: UndoManager? {
        activeTab?.document?.undoManager
    }

    // MARK: - Autosave

    private func startAutosaveTimer() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.autosaveAllDocuments()
        }
    }

    private func autosaveAllDocuments() {
        for tab in openTabs where tab.isDirty {
            tab.document?.autosave(withImplicitCancellability: true) { _ in }
        }
    }

    // MARK: - Action Dispatch

    func dispatchAction(_ action: DocumentAction) {
        activeTab?.viewModel.handleAction(action)
    }

    deinit {
        autosaveTimer?.invalidate()
        backgroundIndexTask?.cancel()
    }
}
