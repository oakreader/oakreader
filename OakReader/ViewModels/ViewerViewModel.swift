import Foundation
import PDFKit
import AppKit

@Observable
class ViewerViewModel {
    weak var parent: DocumentViewModel?

    // MARK: - Search State

    var searchQuery: String = ""
    var searchResults: [PDFSelection] = []
    var currentSearchIndex: Int = 0
    var isSearching: Bool = false

    // MARK: - Navigation History

    private var pageHistory: [Int] = []

    // MARK: - Zoom Constants

    private let minZoom: CGFloat = 0.1
    private let maxZoom: CGFloat = 10.0
    private let zoomStep: CGFloat = 0.25

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    // MARK: - Computed Properties

    private var state: DocumentState? { parent?.state }
    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    var currentPageIndex: Int {
        get { state?.currentPageIndex ?? 0 }
        set { state?.currentPageIndex = newValue }
    }

    var zoomLevel: CGFloat {
        get { state?.zoomLevel ?? 1.0 }
        set { state?.zoomLevel = newValue }
    }

    var displayMode: PDFDisplayMode {
        get { state?.displayMode ?? .singlePageContinuous }
        set { state?.displayMode = newValue }
    }

    var pageCount: Int {
        pdfDocument?.pageCount ?? 0
    }

    var canGoToPreviousPage: Bool {
        currentPageIndex > 0
    }

    var canGoToNextPage: Bool {
        currentPageIndex < pageCount - 1
    }

    var currentPageLabel: String {
        guard let doc = pdfDocument,
              let page = doc.page(at: currentPageIndex) else {
            return "Page 0 of 0"
        }
        let label = page.label ?? "\(currentPageIndex + 1)"
        return "Page \(label) of \(pageCount)"
    }

    var hasSearchResults: Bool {
        !searchResults.isEmpty
    }

    var searchResultLabel: String {
        guard hasSearchResults else { return "" }
        return "\(currentSearchIndex + 1) of \(searchResults.count)"
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        guard let doc = pdfDocument,
              index >= 0, index < doc.pageCount else { return }
        let old = currentPageIndex
        currentPageIndex = index
        if old != index {
            pageHistory.append(old)
            if pageHistory.count > 50 { pageHistory.removeFirst() }
        }
    }

    func goBack() {
        guard let prev = pageHistory.popLast() else { return }
        guard let doc = pdfDocument,
              prev >= 0, prev < doc.pageCount else { return }
        currentPageIndex = prev
    }

    func goToFirstPage() {
        goToPage(0)
    }

    func goToLastPage() {
        goToPage(pageCount - 1)
    }

    func nextPage() {
        if canGoToNextPage {
            goToPage(currentPageIndex + 1)
        }
    }

    func previousPage() {
        if canGoToPreviousPage {
            goToPage(currentPageIndex - 1)
        }
    }

    // MARK: - Zoom

    func setZoom(_ level: CGFloat) {
        zoomLevel = min(max(level, minZoom), maxZoom)
    }

    func zoomIn() {
        setZoom(zoomLevel + zoomStep)
    }

    func zoomOut() {
        setZoom(zoomLevel - zoomStep)
    }

    func zoomToFit() {
        // Reset to a standard 1.0 level; actual fit-to-window
        // is handled by the PDFView in the view layer
        setZoom(1.0)
    }

    func zoomToActualSize() {
        setZoom(1.0)
    }

    func zoomToWidth() {
        // Signal the view to auto-scale to width
        // The view layer reads this and adjusts PDFView.autoScales
        setZoom(1.0)
    }

    var zoomPercentage: String {
        "\(Int(zoomLevel * 100))%"
    }

    // MARK: - Display Mode

    func setDisplayMode(_ mode: PDFDisplayMode) {
        displayMode = mode
        Preferences.shared.displayMode = mode
    }

    // MARK: - Search

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let doc = pdfDocument else {
            await MainActor.run {
                searchResults = []
                currentSearchIndex = 0
                searchQuery = ""
                isSearching = false
                syncSearchStateToParent()
            }
            return
        }

        await MainActor.run {
            searchQuery = trimmed
            isSearching = true
        }

        let results = await Task.detached { [trimmed] () -> [PDFSelection] in
            doc.searchAll(trimmed, options: [.caseInsensitive])
        }.value

        await MainActor.run {
            searchResults = results
            currentSearchIndex = results.isEmpty ? 0 : 0
            isSearching = false
            syncSearchStateToParent()

            if let firstResult = results.first, let page = firstResult.pages.first {
                let pageIndex = doc.index(for: page)
                goToPage(pageIndex)
            }
        }
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        navigateToCurrentSearchResult()
        syncSearchStateToParent()
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        navigateToCurrentSearchResult()
        syncSearchStateToParent()
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        currentSearchIndex = 0
        isSearching = false
        syncSearchStateToParent()
    }

    private func navigateToCurrentSearchResult() {
        guard currentSearchIndex < searchResults.count,
              let doc = pdfDocument else { return }
        let selection = searchResults[currentSearchIndex]
        if let page = selection.pages.first {
            let pageIndex = doc.index(for: page)
            goToPage(pageIndex)
        }
    }

    private func syncSearchStateToParent() {
        guard let state else { return }
        state.searchQuery = searchQuery
        state.searchResults = searchResults
        state.currentSearchIndex = currentSearchIndex
    }

    // MARK: - Selection

    var currentSelection: PDFSelection? {
        guard currentSearchIndex < searchResults.count else { return nil }
        let selection = searchResults[currentSearchIndex]
        selection.color = PDFDefaults.searchHighlightColor
        return selection
    }
}
