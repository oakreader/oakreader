import Foundation
import PDFKit
import AppKit
import OakVoice

// MARK: - Tab Content

enum TabContent {
    case pdf(OakReaderDocument)
    case webSnapshot(WebSnapshotDocument)
    case media(MediaDocument)
    case markdown(MarkdownDocument)
}

// MARK: - Document Tab

@Observable
final class DocumentTab: Identifiable {
    let id: UUID
    let content: TabContent
    let viewModel: DocumentViewModel
    var title: String
    /// Storage key for this document's managed directory (nil for unsaved/blank documents).
    let storageKey: String?

    /// The PDF document, if this tab holds one.
    var document: OakReaderDocument? {
        if case .pdf(let doc) = content { return doc }
        return nil
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

    init(webSnapshot: WebSnapshotDocument, storageKey: String? = nil) {
        self.id = UUID()
        self.content = .webSnapshot(webSnapshot)
        self.viewModel = DocumentViewModel(webSnapshot: webSnapshot)
        self.title = webSnapshot.htmlURL.deletingPathExtension().lastPathComponent
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

}

// MARK: - App State

@Observable
final class AppState {
    let libraryStore: LibraryStore
    let coverService = LibraryCoverService()
    let referenceService: ReferenceService
    let importService: ImportService
    var semanticIndexService: SemanticIndexService?
    private var backgroundIndexTask: Task<Void, Never>?



    var openTabs: [DocumentTab] = []
    var activeTabID: UUID?
    var window: NSWindow?
    var selectedLibraryItemIDs: Set<UUID> = []
    var showSettings: Bool = false
    var showZoteroImport: Bool = false
    var zoteroImportDataDir: URL?
    var isLibrarySidebarVisible: Bool = true
    var libraryDetailTab: LibraryDetailTab? = .metadata

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

    var activeTab: DocumentTab? {
        guard let id = activeTabID else { return nil }
        return openTabs.first { $0.id == id }
    }

    var selectedLibraryItem: LibraryItem? {
        guard let firstID = selectedLibraryItemIDs.first else { return nil }
        return libraryStore.items.first { $0.id == firstID }
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

        // Initialize semantic index service asynchronously
        startSemanticIndexing(database: database)

        // Listen for rebuild requests from settings
        NotificationCenter.default.addObserver(
            forName: .semanticIndexRebuildRequested,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.backgroundIndexTask?.cancel()
            self.startSemanticIndexing(database: self.libraryStore.database)
        }
    }

    private func startSemanticIndexing(database: CatalogDatabase) {
        backgroundIndexTask = Task {
            let defaultEmbedding = KnownModels.embedding.first?.repo ?? ""
            let embeddingRepo = Preferences.shared.embeddingModel.isEmpty
                ? defaultEmbedding
                : Preferences.shared.embeddingModel

            guard await ModelManager.shared.isDownloaded(embeddingRepo) else {
                Log.info(Log.semantic, "Embedding model not downloaded, skipping semantic service")
                return
            }

            do {
                let embeddingService = EmbeddingService(modelId: embeddingRepo)
                try await embeddingService.loadModel()

                let semanticDB = try SemanticDatabase()
                let dimensions = try await embeddingService.embed(text: "test").count
                let searchEngine = HybridSearchEngine(
                    semanticDB: semanticDB,
                    dimensions: UInt32(dimensions)
                )

                let service = SemanticIndexService.create(
                    embeddingService: embeddingService,
                    semanticDB: semanticDB,
                    searchEngine: searchEngine,
                    catalogDBQueue: database.dbQueue
                )
                await MainActor.run {
                    self.semanticIndexService = service
                    self.importService.semanticIndexService = service
                    self.libraryStore.semanticIndexService = service
                }
                Log.info(Log.semantic, "Semantic index service initialized")
                await service.backgroundIndexAll()
            } catch {
                Log.error(Log.semantic, "Failed to initialize semantic index service: \(error)")
            }
        }
    }

    // MARK: - Tab Operations

    /// Open a document from a URL. Dispatches to PDF, web snapshot, or markdown based on file extension.
    func openDocument(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            openHTMLDocument(url: url)
            return
        }
        if ext == "md" || ext == "markdown" {
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
            openTabs.append(tab)
            activeTabID = tab.id
            updateWindowTitle()
        } catch {
            Log.error(Log.open, "Failed to open markdown: \(url.lastPathComponent) — \(error)")
            NSAlert(error: error).runModal()
        }
    }

    /// Open an HTML file as a web snapshot.
    private func openHTMLDocument(url: URL) {
        let item = importService.importWebSnapshot(from: url)
        let htmlURL = item?.fileURL ?? url
        let storageKey = item?.storageKey

        do {
            let snapshot = try WebSnapshotDocument(htmlURL: htmlURL, sourceURL: item?.sourceURL)
            let tab = DocumentTab(webSnapshot: snapshot, storageKey: storageKey)
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
        switch item.contentType {
        case .html:
            openWebSnapshotItem(item)
        case .pdf:
            openPDFItem(item)
        case .video:
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
        libraryStore.markOpened(item)

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

    private func openWebSnapshotItem(_ item: LibraryItem) {
        let htmlURL = item.fileURL
        // Check if already open by storage key
        if let existing = openTabs.first(where: { $0.storageKey == item.storageKey }) {
            switchToTab(existing.id)
            return
        }

        guard FileManager.default.fileExists(atPath: htmlURL.path) else {
            let alert = NSAlert()
            alert.messageText = "Cannot Open Web Snapshot"
            alert.informativeText = "The file \"\(item.title)\" could not be found in managed storage."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        do {
            let snapshot = try WebSnapshotDocument(htmlURL: htmlURL, sourceURL: item.sourceURL)
            libraryStore.markOpened(item)

            let tab = DocumentTab(webSnapshot: snapshot, storageKey: item.storageKey)
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
            Log.error(Log.open, "Failed to open web snapshot: \(item.title) — \(error)")
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
            libraryStore.markOpened(item)

            let tab = DocumentTab(media: media, storageKey: item.storageKey)
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
            alert.messageText = "Cannot Open Note"
            alert.informativeText = "The file \"\(item.title)\" could not be found in managed storage."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        do {
            let mdDoc = try MarkdownDocument(fileURL: mdURL)
            libraryStore.markOpened(item)

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
