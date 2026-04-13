import Foundation
import PDFKit
import AppKit
import SwiftData

// MARK: - Document Tab

@Observable
final class DocumentTab: Identifiable {
    let id: UUID
    let document: OakReaderDocument
    let viewModel: DocumentViewModel
    var title: String
    /// Security-scoped URL kept alive for bookmark-based file access
    private var securityScopedURL: URL?

    var isDirty: Bool {
        document.hasUnautosavedChanges || document.isDocumentEdited
    }

    init(document: OakReaderDocument, securityScopedURL: URL? = nil) {
        self.id = UUID()
        self.document = document
        self.viewModel = document.documentViewModel
        self.title = document.fileURL?.lastPathComponent ?? "Untitled"
        self.securityScopedURL = securityScopedURL
    }

    /// Release security-scoped resource when tab is done
    func releaseSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }
}

// MARK: - App State

@Observable
final class AppState {
    let libraryStore: LibraryStore
    let coverService = LibraryCoverService()

    var openTabs: [DocumentTab] = []
    var activeTabID: UUID?
    var window: NSWindow?
    var selectedLibraryItemIDs: Set<UUID> = []

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
        self.libraryStore = LibraryStore()
        startAutosaveTimer()
    }

    // MARK: - Tab Operations

    /// Open a document from a URL.
    /// - Parameters:
    ///   - url: File URL (may be security-scoped)
    ///   - securityScoped: If true, the URL's security scope is kept alive for the tab's lifetime
    func openDocument(url: URL, securityScoped: Bool = false) {
        // Check if already open
        if let existing = openTabs.first(where: { $0.document.fileURL == url }) {
            // Release the extra security scope since we don't need it
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            switchToTab(existing.id)
            return
        }

        let doc = OakReaderDocument()
        do {
            NSLog("[Open] Reading PDF from: \(url.path)")
            try doc.read(from: url, ofType: "com.adobe.pdf")
            doc.fileURL = url
            NSLog("[Open] Successfully read PDF: \(url.lastPathComponent)")
        } catch {
            NSLog("[Open] FAILED to read PDF: \(url.lastPathComponent) — \(error)")
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            NSAlert(error: error).runModal()
            return
        }

        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        // Add to library & generate cover
        if let item = libraryStore.addItem(from: url) {
            libraryStore.markOpened(item)
            if item.coverImageData == nil {
                Task {
                    if let data = await coverService.generateCover(for: url) {
                        await MainActor.run { libraryStore.updateCover(item, imageData: data) }
                    }
                }
            }
        }

        let tab = DocumentTab(document: doc, securityScopedURL: securityScoped ? url : nil)
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

        tab.releaseSecurityScope()
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
        // Title is hidden in the title bar; document name is shown in tabs.
        // Keep a short title for Window menu / Mission Control.
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
