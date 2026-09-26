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

    /// Find and transiently highlight a citation's `text` (best-effort, tolerant of the
    /// model wrapping a verbatim phrase in extra descriptive words). Prefers the cited
    /// `page` (0-based) when the phrase recurs. The highlight is a temporary, non-persisted
    /// annotation that lingers for `citationHighlightDuration` and survives clicks — it is
    /// never written to the DB nor marks the document edited.
    func highlightCitation(text: String, page: Int?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let doc = pdfDocument else { return }

        let results = await Task.detached { [trimmed, page] () -> [PDFSelection] in
            doc.searchQuote(trimmed, preferredPage: page)
        }.value

        await MainActor.run {
            guard let selection = results.first, let firstPage = selection.pages.first else { return }
            goToPage(doc.index(for: firstPage))
            flashCitationHighlight(selection)
        }
    }

    // MARK: - Citation Highlight (temporary, non-persisted)

    /// The passage a citation click is currently highlighting. Drives a one-shot scroll
    /// into view in `PDFViewerRepresentable` (the visible mark is the annotation below).
    var citationHighlight: PDFSelection?
    /// Bumped on each citation click so the viewer recentres on the new passage exactly once.
    var citationHighlightSeq: Int = 0

    private var citationAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var citationHighlightToken = 0

    /// How long a citation highlight stays on screen. Generous so the reader has time to
    /// find the passage; because it's an annotation (not a PDFView selection) it survives
    /// clicks rather than vanishing on the first interaction.
    private let citationHighlightDuration: TimeInterval = 10

    @MainActor
    private func flashCitationHighlight(_ selection: PDFSelection) {
        clearCitationHighlight()
        let color = PDFDefaults.searchHighlightColor
        for page in selection.pages {
            var quads: [NSValue] = []
            var union = CGRect.null
            for line in selection.selectionsByLine() {
                let b = line.bounds(for: page)
                guard b.width > 0, b.height > 0 else { continue }   // line not on this page
                union = union.union(b)
                quads.append(NSValue(point: NSPoint(x: b.minX, y: b.minY)))
                quads.append(NSValue(point: NSPoint(x: b.maxX, y: b.minY)))
                quads.append(NSValue(point: NSPoint(x: b.minX, y: b.maxY)))
                quads.append(NSValue(point: NSPoint(x: b.maxX, y: b.maxY)))
            }
            guard !union.isNull else { continue }
            let annotation = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
            annotation.color = color
            if !quads.isEmpty { annotation.setValue(quads, forAnnotationKey: .quadPoints) }
            page.addAnnotation(annotation)
            citationAnnotations.append((page, annotation))
        }

        citationHighlight = selection
        citationHighlightSeq &+= 1

        citationHighlightToken &+= 1
        let token = citationHighlightToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.citationHighlightDuration ?? 10))
            guard let self, self.citationHighlightToken == token else { return }
            self.clearCitationHighlight()
        }
    }

    /// Remove the current temporary citation highlight, if any.
    @MainActor
    func clearCitationHighlight() {
        for (page, annotation) in citationAnnotations {
            page.removeAnnotation(annotation)
        }
        citationAnnotations.removeAll()
        citationHighlight = nil
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
