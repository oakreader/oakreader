import Foundation
import PDFKit
import AppKit

// MARK: - Document Tab

@Observable
final class DocumentTab: Identifiable {
    let id: UUID
    let document: OakReaderDocument
    let viewModel: DocumentViewModel
    var title: String
    /// Storage key for this document's managed directory (nil for unsaved/blank documents).
    let storageKey: String?

    var isDirty: Bool {
        document.hasUnautosavedChanges || document.isDocumentEdited
    }

    init(document: OakReaderDocument, storageKey: String? = nil) {
        self.id = UUID()
        self.document = document
        self.viewModel = document.documentViewModel
        self.title = document.fileURL?.lastPathComponent ?? "Untitled"
        self.storageKey = storageKey
    }
}

// MARK: - App State

@Observable
final class AppState {
    let libraryStore: LibraryStore
    let coverService = LibraryCoverService()
    let importService: ImportService

    var openTabs: [DocumentTab] = []
    var activeTabID: UUID?
    var window: NSWindow?
    var selectedLibraryItemIDs: Set<UUID> = []
    var showSettings: Bool = false

    private var autosaveTimer: Timer?

    var isLibraryActive: Bool {
        activeTabID == nil
    }

    var activeTab: DocumentTab? {
        guard let id = activeTabID else { return nil }
        return openTabs.first { $0.id == id }
    }

    var selectedLibraryItem: PDFLibraryItem? {
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
        self.importService = ImportService(store: libraryStore, coverService: coverService)
        startAutosaveTimer()
    }

    // MARK: - Tab Operations

    /// Open a document from a URL. If the PDF is not already in managed storage, it will be imported first.
    func openDocument(url: URL) {
        // Check if already open by URL
        if let existing = openTabs.first(where: { $0.document.fileURL == url }) {
            switchToTab(existing.id)
            return
        }

        // Import into managed storage (or find existing)
        let item = importService.importPDF(from: url)
        let pdfURL = item?.fileURL ?? url
        let storageKey = item?.storageKey

        // Check if the managed URL is already open
        if let item, let existing = openTabs.first(where: { $0.document.fileURL == item.fileURL }) {
            switchToTab(existing.id)
            return
        }

        let doc = OakReaderDocument()
        do {
            NSLog("[Open] Reading PDF from: \(pdfURL.path)")
            try doc.read(from: pdfURL, ofType: "com.adobe.pdf")
            doc.fileURL = pdfURL
            NSLog("[Open] Successfully read PDF: \(pdfURL.lastPathComponent)")
        } catch {
            NSLog("[Open] FAILED to read PDF: \(pdfURL.lastPathComponent) — \(error)")
            NSAlert(error: error).runModal()
            return
        }

        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        if let item {
            libraryStore.markOpened(item)
        }

        let tab = DocumentTab(document: doc, storageKey: storageKey)
        // Use original filename (not "document.pdf" from managed storage)
        tab.title = item?.fileName ?? url.lastPathComponent
        NSDocumentController.shared.addDocument(doc)
        openTabs.append(tab)
        activeTabID = tab.id
        updateWindowTitle()
    }

    /// Open a library item directly (already imported).
    func openLibraryItem(_ item: PDFLibraryItem) {
        let pdfURL = item.fileURL

        // Check if already open
        if let existing = openTabs.first(where: { $0.document.fileURL == pdfURL }) {
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
            NSLog("[Open] FAILED to read PDF: \(item.title) — \(error)")
            NSAlert(error: error).runModal()
            return
        }

        NSDocumentController.shared.noteNewRecentDocumentURL(pdfURL)
        libraryStore.markOpened(item)

        let tab = DocumentTab(document: doc, storageKey: item.storageKey)
        // Use original filename from library item
        tab.title = item.fileName
        NSDocumentController.shared.addDocument(doc)
        openTabs.append(tab)
        activeTabID = tab.id
        updateWindowTitle()
    }

    func openBlankDocument() {
        let doc = OakReaderDocument()
        let newPDF = PDFDocument()
        let blankPage = PDFPage.blankPage()
        newPDF.insert(blankPage, at: 0)
        doc.pdfDocument = newPDF
        doc.documentViewModel = DocumentViewModel(document: doc)

        NSDocumentController.shared.addDocument(doc)

        let tab = DocumentTab(document: doc)
        openTabs.append(tab)
        activeTabID = tab.id
        updateWindowTitle()
    }

    func closeTab(_ tabID: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = openTabs[index]

        // Check for unsaved changes
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = "Do you want to save changes to \"\(tab.title)\"?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                tab.document.save(nil)
            case .alertThirdButtonReturn:
                return // Cancel close
            default:
                break
            }
        }

        tab.document.close()
        openTabs.remove(at: index)

        if activeTabID == tabID {
            if openTabs.isEmpty {
                activeTabID = nil
            } else {
                let newIndex = min(index, openTabs.count - 1)
                activeTabID = openTabs[newIndex].id
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
        guard let currentID = activeTabID,
              let currentIndex = openTabs.firstIndex(where: { $0.id == currentID }),
              !openTabs.isEmpty else { return }
        let nextIndex = (currentIndex + 1) % openTabs.count
        switchToTab(openTabs[nextIndex].id)
    }

    func previousTab() {
        guard let currentID = activeTabID,
              let currentIndex = openTabs.firstIndex(where: { $0.id == currentID }),
              !openTabs.isEmpty else { return }
        let prevIndex = (currentIndex - 1 + openTabs.count) % openTabs.count
        switchToTab(openTabs[prevIndex].id)
    }

    // MARK: - Window

    func updateWindowTitle() {
        window?.title = ""
    }

    // MARK: - Undo Manager

    var currentUndoManager: UndoManager? {
        activeTab?.document.undoManager
    }

    // MARK: - Autosave

    private func startAutosaveTimer() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.autosaveAllDocuments()
        }
    }

    private func autosaveAllDocuments() {
        for tab in openTabs where tab.isDirty {
            tab.document.autosave(withImplicitCancellability: true) { _ in }
        }
    }

    // MARK: - Action Dispatch

    func dispatchAction(_ action: DocumentAction) {
        activeTab?.viewModel.handleAction(action)
    }

    deinit {
        autosaveTimer?.invalidate()
    }
}
