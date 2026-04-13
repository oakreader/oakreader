import Foundation
import PDFKit
import AppKit

@Observable
class PageOrganizeViewModel {
    weak var parent: DocumentViewModel?

    var pageModels: [PageModel] = []
    var selectedPages: Set<Int> = []

    init(parent: DocumentViewModel) {
        self.parent = parent
        refreshPageModels()
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Selection

    func selectPage(_ index: Int) {
        selectedPages.insert(index)
    }

    func deselectPage(_ index: Int) {
        selectedPages.remove(index)
    }

    func togglePageSelection(_ index: Int) {
        if selectedPages.contains(index) {
            selectedPages.remove(index)
        } else {
            selectedPages.insert(index)
        }
    }

    func selectAll() {
        guard let doc = pdfDocument else { return }
        selectedPages = Set(0..<doc.pageCount)
    }

    func deselectAll() {
        selectedPages.removeAll()
    }

    // MARK: - Reorder

    func reorderPages(from source: IndexSet, to destination: Int) {
        guard let doc = pdfDocument else { return }

        // Collect the pages to move
        let sortedSource = source.sorted()
        var pages: [PDFPage] = []
        for index in sortedSource {
            guard let page = doc.page(at: index) else { continue }
            if let copied = page.copy() as? PDFPage {
                pages.append(copied)
            }
        }

        // Calculate adjusted destination after removals
        var adjustedDest = destination
        for index in sortedSource.reversed() {
            if index < destination {
                adjustedDest -= 1
            }
            doc.removePage(at: index)
        }

        // Insert pages at the destination
        for (offset, page) in pages.enumerated() {
            let insertIndex = min(adjustedDest + offset, doc.pageCount)
            doc.insert(page, at: insertIndex)
        }

        parent?.markDocumentEdited()
        refreshPageModels()
        selectedPages.removeAll()
    }

    // MARK: - Rotate

    func rotatePage(at index: Int, by degrees: Int) {
        guard let doc = pdfDocument,
              let page = doc.page(at: index) else { return }

        let currentRotation = page.rotation
        let newRotation = (currentRotation + degrees + 360) % 360
        page.rotation = newRotation

        parent?.markDocumentEdited()
        refreshPageModels()
    }

    func rotateSelectedPages(by degrees: Int) {
        for index in selectedPages.sorted() {
            rotatePage(at: index, by: degrees)
        }
    }

    // MARK: - Delete

    func deletePage(at index: Int) {
        guard let doc = pdfDocument,
              doc.pageCount > 1,
              index >= 0, index < doc.pageCount else { return }

        doc.removePage(at: index)
        parent?.markDocumentEdited()

        // Adjust current page index if needed
        if let state = parent?.state {
            if state.currentPageIndex >= doc.pageCount {
                state.currentPageIndex = max(0, doc.pageCount - 1)
            }
        }

        selectedPages.remove(index)
        // Adjust selected page indices
        let adjusted = selectedPages.compactMap { i -> Int? in
            if i > index { return i - 1 }
            if i < index { return i }
            return nil
        }
        selectedPages = Set(adjusted)

        refreshPageModels()
    }

    func deleteSelectedPages() {
        guard let doc = pdfDocument else { return }
        let toDelete = selectedPages.sorted().reversed()

        // Don't delete all pages
        guard doc.pageCount - selectedPages.count >= 1 else {
            parent?.state.presentError("Cannot delete all pages. At least one page must remain.")
            return
        }

        for index in toDelete {
            guard index < doc.pageCount else { continue }
            doc.removePage(at: index)
        }

        parent?.markDocumentEdited()
        selectedPages.removeAll()

        if let state = parent?.state {
            if state.currentPageIndex >= doc.pageCount {
                state.currentPageIndex = max(0, doc.pageCount - 1)
            }
        }

        refreshPageModels()
    }

    // MARK: - Insert

    func insertBlankPage(at index: Int) {
        guard let doc = pdfDocument else { return }

        let insertAt = min(max(index, 0), doc.pageCount)
        let blankPage = PDFPage.blankPage()
        doc.insert(blankPage, at: insertAt)

        parent?.markDocumentEdited()
        refreshPageModels()
    }

    func insertPages(from otherDocument: PDFDocument, at index: Int) {
        guard let doc = pdfDocument else { return }

        var insertAt = min(max(index, 0), doc.pageCount)
        for i in 0..<otherDocument.pageCount {
            guard let page = otherDocument.page(at: i),
                  let copied = page.copy() as? PDFPage else { continue }
            doc.insert(copied, at: insertAt)
            insertAt += 1
        }

        parent?.markDocumentEdited()
        refreshPageModels()
    }

    func insertPage(_ page: PDFPage, at index: Int) {
        guard let doc = pdfDocument else { return }

        let insertAt = min(max(index, 0), doc.pageCount)
        if let copied = page.copy() as? PDFPage {
            doc.insert(copied, at: insertAt)
        } else {
            doc.insert(page, at: insertAt)
        }

        parent?.markDocumentEdited()
        refreshPageModels()
    }

    // MARK: - Extract

    func extractPages(_ indices: IndexSet) {
        guard let doc = pdfDocument,
              !indices.isEmpty else { return }

        let extractedDoc = doc.extractPages(indices)

        guard extractedDoc.pageCount > 0 else {
            parent?.state.presentError("No pages could be extracted.")
            return
        }

        // Present a save panel for the extracted document
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "Extracted Pages.pdf"
        savePanel.canCreateDirectories = true

        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            if extractedDoc.write(to: url) {
                // Open the extracted document
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error {
                        self?.parent?.state.presentError("Failed to open extracted document: \(error.localizedDescription)")
                    }
                }
            } else {
                self?.parent?.state.presentError("Failed to save extracted pages.")
            }
        }
    }

    // MARK: - Duplicate

    func duplicatePage(at index: Int) {
        guard let doc = pdfDocument,
              let page = doc.page(at: index),
              let copied = page.copy() as? PDFPage else { return }

        doc.insert(copied, at: index + 1)
        parent?.markDocumentEdited()
        refreshPageModels()
    }

    // MARK: - Refresh

    func refreshPageModels() {
        guard let doc = pdfDocument else {
            pageModels = []
            return
        }
        pageModels = PageModel.models(from: doc)
    }

    // MARK: - Merge

    func mergeDocument(from url: URL) {
        guard let doc = pdfDocument,
              let otherDoc = PDFDocument(url: url) else {
            parent?.state.presentError("Failed to open document for merging.")
            return
        }
        doc.appendDocument(otherDoc)
        parent?.markDocumentEdited()
        refreshPageModels()
    }

    // MARK: - Split

    func splitDocument(atPageIndex splitIndex: Int) {
        guard let doc = pdfDocument,
              splitIndex > 0, splitIndex < doc.pageCount else {
            parent?.state.presentError("Invalid split point.")
            return
        }

        let firstPart = doc.extractPages(IndexSet(0..<splitIndex))
        let secondPart = doc.extractPages(IndexSet(splitIndex..<doc.pageCount))

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "Split Part 1.pdf"
        savePanel.canCreateDirectories = true
        savePanel.message = "Save the first part"

        savePanel.begin { response in
            guard response == .OK, let url1 = savePanel.url else { return }
            firstPart.write(to: url1)

            let savePanel2 = NSSavePanel()
            savePanel2.allowedContentTypes = [.pdf]
            savePanel2.nameFieldStringValue = "Split Part 2.pdf"
            savePanel2.canCreateDirectories = true
            savePanel2.message = "Save the second part"

            savePanel2.begin { response2 in
                guard response2 == .OK, let url2 = savePanel2.url else { return }
                secondPart.write(to: url2)
            }
        }
    }
}
