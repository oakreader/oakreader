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

    /// Why a page change happened.
    ///
    /// Ordinary reading must **not** record a return point. Before this split,
    /// every page change went through `goToPage` and pushed onto the history —
    /// so stepping ↓ ten times left ten entries and ⌥⌘ Back walked the reader
    /// backwards one page at a time instead of returning to where they jumped
    /// from. Only deliberate jumps (a chat citation, an outline entry, a search
    /// hit, a note's source) leave a return point worth offering.
    enum PageChangeKind {
        /// ↑/↓, Home/End, thumbnail scrubbing, presentation advance. No return point.
        case reading
        /// A jump from elsewhere in the app — records where the reader came from.
        case jump
    }

    /// Origins of deliberate jumps, most recent last. Page-level only: restoring
    /// the exact scroll offset needs the `PDFDestination` the view layer owns, so
    /// returning lands at the top of the origin page.
    private var jumpOrigins: [Int] = []

    /// The page `jumpBack()` would return to, or `nil` when the reader hasn't
    /// jumped. Drives the "Back to p. N" affordance.
    var returnPage: Int? { jumpOrigins.last }

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

    var hasSearchResults: Bool {
        !searchResults.isEmpty
    }

    var searchResultLabel: String {
        guard hasSearchResults else { return "" }
        return "\(currentSearchIndex + 1) of \(searchResults.count)"
    }

    // MARK: - Navigation

    /// Move to `index` (0-based). `kind` decides whether the departure point is
    /// remembered — see `PageChangeKind`. Defaults to `.reading` so a call site
    /// that forgets to classify itself fails safe (a missing return point is a
    /// minor loss; a polluted history is the bug this split exists to fix).
    func goToPage(_ index: Int, kind: PageChangeKind = .reading) {
        guard let doc = pdfDocument,
              index >= 0, index < doc.pageCount else { return }
        let old = currentPageIndex
        currentPageIndex = index
        guard kind == .jump, old != index else { return }
        jumpOrigins.append(old)
        if jumpOrigins.count > 50 { jumpOrigins.removeFirst() }
    }

    /// Return to the page the most recent jump departed from, consuming it.
    func jumpBack() {
        guard let prev = jumpOrigins.popLast() else { return }
        guard let doc = pdfDocument,
              prev >= 0, prev < doc.pageCount else { return }
        currentPageIndex = prev
    }

    /// Legacy spelling kept for the Go ▸ Back menu item and its ⌥⌘[ shortcut.
    func goBack() { jumpBack() }

    // MARK: - Section (outline enrichment)

    /// The outline heading covering `currentPageIndex`, or `nil` when the document
    /// has no usable outline.
    ///
    /// Walked from `outlineRoot` rather than `BookmarkModel`, which substitutes
    /// page 0 for entries that carry no destination — those would otherwise match
    /// every page and mislabel the whole document. Entries without a real
    /// destination are skipped here instead. When several headings start on the
    /// current page the last one wins, which is what a reader scrolling down sees.
    var currentSectionLabel: String? {
        let entries = sectionIndex()
        // A single-entry outline tells the reader nothing they don't already know.
        guard entries.count > 1 else { return nil }
        let page = currentPageIndex
        var best: String?
        for entry in entries where entry.page <= page {
            best = entry.label
        }
        return best
    }

    /// Flattened outline, sorted by page, built once per document. Page changes
    /// fire continuously while scrolling, so this must not re-walk the outline
    /// on every one.
    private func sectionIndex() -> [(page: Int, label: String)] {
        guard let doc = pdfDocument else { return [] }
        if let cached = cachedSectionIndex, cachedSectionIndexDocument === doc { return cached }

        var entries: [(page: Int, label: String)] = []
        if let root = doc.outlineRoot {
            var stack: [PDFOutline] = (0..<root.numberOfChildren).compactMap { root.child(at: $0) }
            while let node = stack.popLast() {
                if let destinationPage = node.destination?.page,
                   let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !label.isEmpty {
                    entries.append((doc.index(for: destinationPage), label))
                }
                for i in 0..<node.numberOfChildren {
                    if let child = node.child(at: i) { stack.append(child) }
                }
            }
            entries.sort { $0.page < $1.page }
        }
        cachedSectionIndex = entries
        cachedSectionIndexDocument = doc
        return entries
    }

    @ObservationIgnored private var cachedSectionIndex: [(page: Int, label: String)]?
    @ObservationIgnored private weak var cachedSectionIndexDocument: PDFDocument?

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
                goToPage(pageIndex, kind: .jump)
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
            goToPage(doc.index(for: firstPage), kind: .jump)
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
            goToPage(pageIndex, kind: .jump)
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
