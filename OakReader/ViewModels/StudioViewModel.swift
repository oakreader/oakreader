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

        let source = Self.sourceText(from: parent)
        guard !source.isEmpty else {
            errorMessage = "This document has no extractable text to generate from."
            return
        }
        let docTitle = parent.libraryItem?.title ?? parent.fileName

        Analytics.capture("studio_generate", properties: ["kind": kind.rawValue])
        errorMessage = nil
        generatingKind = kind
        streamingDeck = nil
        streamingMindmapOutline = nil
        genTask?.cancel()

        switch kind {
        case .quiz:
            genTask = Task { @MainActor in
                await runQuiz(source: source, docTitle: docTitle, itemId: itemId, params: params, store: store)
                streamingDeck = nil
                generatingKind = nil
            }
        case .mindmap:
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
        source: String, docTitle: String, itemId: String,
        params: StudioGenerationParams, store: StudioArtifactStore
    ) async {
        var finalTitle = "\(docTitle) — Flashcards"
        var finalCards: [QuizContent] = []
        do {
            for try await snapshot in generator.streamQuiz(
                sourceText: source, documentTitle: docTitle, params: params
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

    /// Persist an edited mind-map outline (from the full-screen Mind Elixir editor).
    @MainActor
    func updateArtifactBody(_ artifact: StudioArtifact, outline: String) {
        guard let store else { return }
        let trimmed = outline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = artifact
        updated.body = trimmed
        updated.title = StudioGenerator.titleFromOutline(trimmed) ?? artifact.title
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

    /// Flash the document passage a mind-map node was drawn from. Mirrors the chat
    /// citation jump: PDF uses the viewer's tolerant quote search; web / HTML / live
    /// pages use the WKWebView find-text highlight (`oakHighlightCitation`).
    @MainActor
    func jumpToSource(anchorText: String) {
        guard let parent else { return }
        let text = anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch parent.contentType {
        case .pdf:
            Task { @MainActor in await parent.viewer.highlightCitation(text: text, page: nil) }
        case .html, .markdown, .link:
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

    // MARK: - Source extraction

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
