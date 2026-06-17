import Foundation
import OakAgent

/// Drives the AI Studio panel for a single document: lists the item's generated
/// artifacts, runs one-shot grounded generation, and persists results.
///
/// Replaces the old chat-native quiz model — artifacts are first-class rows in
/// `studio_artifacts`, not buried in chat turns. On first open it does a
/// best-effort, one-time import of any legacy chat-generated quiz cards.
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
    /// The mind-map outline being streamed in right now — re-rendered live until
    /// generation finishes and it's persisted.
    var streamingMindmapOutline: String?
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
        var loaded = store.fetch(itemId: itemId)
        // One-time best-effort import of legacy chat-native quiz cards: only when
        // this item has no quiz artifacts yet, so it never runs twice.
        if !loaded.contains(where: { $0.kind == .quiz }) {
            let imported = await importLegacyQuizCards(itemId: itemId, store: store)
            if imported > 0 { loaded = store.fetch(itemId: itemId) }
        }
        artifacts = loaded
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
        streamingMindmapOutline = nil
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
        case .mindmap:
            let source = Self.sourceText(from: parent)
            guard !source.isEmpty else {
                errorMessage = "This document has no extractable text to generate from."
                generatingKind = nil
                return
            }
            genTask = Task { @MainActor in
                await runMindmap(source: source, docTitle: docTitle, itemId: itemId, params: params, store: store)
                streamingMindmapOutline = nil
                generatingKind = nil
            }
        case .deck, .audio:
            generatingKind = nil  // not yet wired
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

    /// Stream a mind-map outline, re-rendering `streamingMindmapOutline` live,
    /// then persist it.
    @MainActor
    private func runMindmap(
        source: String, docTitle: String, itemId: String,
        params: StudioGenerationParams, store: StudioArtifactStore
    ) async {
        var finalOutline = ""
        do {
            for try await outline in generator.streamMindmap(
                sourceText: source, documentTitle: docTitle, params: params
            ) {
                finalOutline = outline
                streamingMindmapOutline = outline
            }
            let trimmed = finalOutline.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let title = StudioGenerator.titleFromOutline(trimmed) ?? "\(docTitle) — Mind Map"
                let artifact = StudioArtifact(
                    itemId: itemId, kind: .mindmap, title: title, body: trimmed, params: params
                )
                store.upsert(artifact)
                artifacts.insert(artifact, at: 0)
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    /// Persist an edited mind-map body (from the Mind Elixir editor). The body is
    /// either the streamed outline or — once the map has rich content / been hand
    /// edited — a Mind Elixir JSON object; both are stored verbatim.
    @MainActor
    func updateArtifactBody(_ artifact: StudioArtifact, body: String) {
        guard let store else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = artifact
        updated.body = trimmed
        updated.title = StudioGenerator.titleFromBody(trimmed) ?? artifact.title
        updated.updatedAt = Date()
        store.upsert(updated)
        if let idx = artifacts.firstIndex(where: { $0.id == artifact.id }) {
            artifacts[idx] = updated
        }
    }

    func cancelGeneration() {
        genTask?.cancel()
        genTask = nil
        streamingDeck = nil
        generatingKind = nil
    }

    // MARK: - Jump to source

    /// Flash the document passage an artifact (mind-map node, flashcard) was drawn
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

    // MARK: - Legacy import

    /// Import quiz cards from the item's chat history (the old chat-native model)
    /// into `studio_artifacts`. Returns the number of decks imported.
    @MainActor
    private func importLegacyQuizCards(itemId: String, store: StudioArtifactStore) async -> Int {
        guard let database = parent?.database else { return 0 }
        let conversations = ConversationService(database: database)
        let sessionStore = SessionStore(baseDirectory: CatalogDatabase.chatsDirectory)
        let metas = (try? conversations.fetchSessions(forItemId: itemId)) ?? []

        var count = 0
        for meta in metas {
            let turns = (try? await sessionStore.loadTurns(sessionId: meta.id)) ?? []
            for turn in turns {
                for use in turn.toolUses where use.name == "quiz_cards" {
                    guard let deck = Self.legacyDeck(from: use) else { continue }
                    let title = deck.title.isEmpty ? "Imported flashcards" : deck.title
                    let body = QuizCardCodec.bodyJSON(title: title, cards: deck.cards)
                    let artifact = StudioArtifact(
                        itemId: itemId,
                        kind: .quiz,
                        title: title,
                        body: body,
                        createdAt: meta.lastMessageAt,
                        updatedAt: meta.lastMessageAt
                    )
                    if store.upsert(artifact) { count += 1 }
                }
            }
        }
        return count
    }

    /// Reconstruct a deck from a persisted `quiz_cards` tool-use record.
    private static func legacyDeck(from record: ToolUseRecord) -> QuizDeck? {
        guard let cardValues = record.input.array("cards") else { return nil }
        let cards: [QuizContent] = cardValues.compactMap { value in
            guard JSONSerialization.isValidJSONObject(value.anyValue),
                  let data = try? JSONSerialization.data(withJSONObject: value.anyValue)
            else { return nil }
            return try? JSONDecoder().decode(QuizContent.self, from: data)
        }
        guard !cards.isEmpty else { return nil }
        return QuizDeck(title: record.input["title"] ?? "", cards: cards)
    }
}
