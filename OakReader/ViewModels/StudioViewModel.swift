import Foundation
import OakAgent

/// Drives the AI Studio panel for a single document: lists the item's generated
/// artifacts, runs one-shot grounded generation, and persists results.
///
/// Replaces the old chat-native quiz model — artifacts are first-class rows in
/// `studio_artifacts`, not buried in chat turns.
@Observable
final class StudioViewModel {
    weak var parent: DocumentViewModel?

    var artifacts: [StudioArtifact] = []
    var isLoaded = false
    /// Non-nil while a generation is in flight (drives the tile's spinner).
    var generatingKind: StudioArtifactKind?
    /// The deck being streamed in right now — grows card-by-card; shown at the
    /// top of the panel until generation finishes and it's persisted.
    var streamingDeck: QuizDeck?
    var errorMessage: String?

    private let generator = StudioGenerator()
    private var genTask: Task<Void, Never>?

    init(parent: DocumentViewModel?) {
        self.parent = parent
    }

    private var store: StudioArtifactStore? {
        guard let db = parent?.database else { return nil }
        return StudioArtifactStore(database: db)
    }

    // MARK: - Load

    @MainActor
    func reload() async {
        guard let store, let itemId = parent?.itemId else {
            artifacts = []
            isLoaded = true
            return
        }
        artifacts = store.fetch(itemId: itemId)
        isLoaded = true
    }

    // MARK: - Generate

    @MainActor
    func generate(kind: StudioArtifactKind, params: StudioGenerationParams) {
        guard kind.isAvailable else { return }
        guard let store, let parent, let itemId = parent.itemId else { return }

        let docTitle = parent.libraryItem?.title ?? parent.fileName

        Analytics.capture("studio_generate", properties: ["kind": kind.rawValue])
        errorMessage = nil
        generatingKind = kind
        streamingDeck = nil
        genTask?.cancel()

        switch kind {
        case .quiz:
            // Quiz uses a paginated source so cards can cite their page and a
            // large document is chunked by page range rather than truncated.
            let source = Self.studioSource(from: parent)
            guard !source.isEmpty else {
                errorMessage = "This document has no extractable text to generate from."
                generatingKind = nil
                return
            }
            genTask = Task { @MainActor in
                await runQuiz(source: source, docTitle: docTitle, itemId: itemId, params: params, store: store)
                streamingDeck = nil
                generatingKind = nil
            }
        }
    }

    /// Stream a flashcard deck, growing `streamingDeck`, then persist it.
    @MainActor
    private func runQuiz(
        source: StudioSource, docTitle: String, itemId: String,
        params: StudioGenerationParams, store: StudioArtifactStore
    ) async {
        var finalTitle = "\(docTitle) — Flashcards"
        var finalCards: [QuizContent] = []
        do {
            for try await snapshot in generator.streamQuiz(
                source: source, documentTitle: docTitle, params: params
            ) {
                if let t = snapshot.title, !t.isEmpty { finalTitle = t }
                finalCards = snapshot.cards
                streamingDeck = QuizDeck(title: finalTitle, cards: snapshot.cards)
            }
            if !finalCards.isEmpty {
                let body = QuizCardCodec.bodyJSON(title: finalTitle, cards: finalCards)
                let artifact = StudioArtifact(
                    itemId: itemId, kind: .quiz, title: finalTitle, body: body, params: params
                )
                store.upsert(artifact)
                artifacts.insert(artifact, at: 0)
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func cancelGeneration() {
        genTask?.cancel()
        genTask = nil
        streamingDeck = nil
        generatingKind = nil
    }

    // MARK: - Jump to source

    /// Flash the document passage an artifact (concept node, flashcard) was drawn
    /// from. Mirrors the chat citation jump: PDF uses the viewer's tolerant quote
    /// search, preferring `page1Based` when given; web / HTML / live pages use the
    /// WKWebView find-text highlight (`oakHighlightCitation`).
    @MainActor
    func jumpToSource(anchorText: String, page1Based: Int? = nil) {
        guard let parent else { return }
        let text = anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch parent.contentType {
        case .pdf:
            let pageIndex = page1Based.map { max(0, $0 - 1) }
            if text.isEmpty {
                if let pageIndex { parent.viewer.goToPage(pageIndex) }
            } else {
                Task { @MainActor in await parent.viewer.highlightCitation(text: text, page: pageIndex) }
            }
        case .html, .markdown, .link:
            guard !text.isEmpty else { return }
            NotificationCenter.default.post(name: .webViewFindText, object: text)
        case .audio:
            break
        }
    }

    // MARK: - Delete

    func delete(_ artifact: StudioArtifact) {
        store?.delete(id: artifact.id)
        artifacts.removeAll { $0.id == artifact.id }
    }

    /// Remove a single flashcard from a quiz deck and re-persist it. Deleting the
    /// deck's last card removes the whole artifact.
    @MainActor
    func deleteQuizCard(_ artifact: StudioArtifact, at index: Int) {
        guard let store, let deck = artifact.quizDeck,
              deck.cards.indices.contains(index) else { return }
        var cards = deck.cards
        cards.remove(at: index)
        if cards.isEmpty {
            delete(artifact)
            return
        }
        var updated = artifact
        updated.body = QuizCardCodec.bodyJSON(title: deck.title, cards: cards)
        updated.updatedAt = Date()
        store.upsert(updated)
        if let idx = artifacts.firstIndex(where: { $0.id == artifact.id }) {
            artifacts[idx] = updated
        }
    }

    // MARK: - Source extraction

    /// A paginated grounding source for quiz generation. For PDFs this preserves
    /// per-page text (so cards cite pages and large docs chunk by page range);
    /// other types fall back to a single unpaginated block.
    @MainActor
    static func studioSource(from vm: DocumentViewModel) -> StudioSource {
        switch vm.contentType {
        case .pdf:
            guard let doc = vm.pdfDocument else { return StudioSource(pages: []) }
            // Overall safety cap so a pathologically large PDF can't blow up the
            // pipeline; chunking keeps each generation call small regardless.
            let cap = 120_000
            var pages: [StudioSourcePage] = []
            var total = 0
            for (index, text) in TextExtractionService().extractTextByPage(from: doc) {
                if total >= cap { break }
                pages.append(StudioSourcePage(number: index + 1, text: text))
                total += text.count
            }
            return StudioSource(pages: pages)
        case .html, .markdown, .link, .audio:
            return StudioSource.plain(sourceText(from: vm))
        }
    }

    /// Pull the document's body text for grounding. Mirrors the per-type logic in
    /// `LLMContextProvider`, but takes the FULL text (capped) since a generator
    /// works over the whole document rather than the current page.
    @MainActor
    static func sourceText(from vm: DocumentViewModel) -> String {
        let cap = 16_000
        switch vm.contentType {
        case .pdf:
            if let doc = vm.pdfDocument {
                return String(TextExtractionService().extractAllText(from: doc).prefix(cap))
            }
        case .html:
            if let snapshot = vm.html {
                let mdURL = snapshot.htmlURL.deletingLastPathComponent()
                    .appendingPathComponent("content.md")
                if let md = try? String(contentsOf: mdURL, encoding: .utf8), !md.isEmpty {
                    return String(md.prefix(cap))
                }
                if let data = try? Data(contentsOf: snapshot.htmlURL) {
                    return String(HTMLTextExtractor.extractText(from: data).prefix(cap))
                }
            }
        case .link:
            if let media = vm.mediaDocument {
                if let url = media.transcriptURL,
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    return String(text.prefix(cap))
                }
                let mdURL = media.storageDirectory.appendingPathComponent("content.md")
                if let md = try? String(contentsOf: mdURL, encoding: .utf8), !md.isEmpty {
                    return String(md.prefix(cap))
                }
                return media.metadata.description ?? ""
            }
        case .markdown:
            if let mdDoc = vm.markdownDocument {
                return String(mdDoc.content.prefix(cap))
            }
        case .audio:
            break
        }
        return ""
    }

}
