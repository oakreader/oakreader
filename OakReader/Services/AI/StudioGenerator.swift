import Foundation
import OakAgent

/// One page of a document's extracted text. `number` is 1-based; `0` marks an
/// unpaginated source (HTML / markdown / media transcript), so cards from it
/// carry no page citation.
struct StudioSourcePage: Sendable {
    let number: Int
    let text: String
}

/// The grounding text for a Studio generation. Paginated when it carries real
/// PDF page numbers — that lets flashcards cite the page they came from and lets
/// large documents be chunked by page range instead of silently truncated.
struct StudioSource: Sendable {
    let pages: [StudioSourcePage]

    /// True when at least one page carries a real (>0) page number.
    var isPaginated: Bool { pages.contains { $0.number > 0 } }

    var isEmpty: Bool {
        pages.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A single, unpaginated block — the fallback for sources without pages.
    static func plain(_ text: String) -> StudioSource {
        StudioSource(pages: [StudioSourcePage(number: 0, text: text)])
    }
}

/// A contiguous run of pages bundled for one generation call, small enough to
/// fit comfortably in context. `pageStart`/`pageEnd` are 0 for unpaginated text.
private struct SourceChunk {
    let pageStart: Int
    let pageEnd: Int
    /// Page-marked text (each page prefixed with `[Page N]`) so the model can
    /// attribute each card to a page.
    let text: String
}

/// One-shot, source-grounded generation of AI Studio artifacts. Mirrors the
/// streaming pattern in `TranslationViewModel`: resolve the user's configured
/// provider, send a single system+user prompt, accumulate the streamed text.
///
/// Each kind has its own method. Phase 1 ships `generateQuiz` and the concept
/// map; deck / audio land in later phases.
struct StudioGenerator {
    /// Page text budget per generation call. Large docs are split into several
    /// chunks of roughly this size so the whole document is covered (not just
    /// the first ~10 pages) and each chunk's cards cite pages within its range.
    private static let chunkCharLimit = 7_000
    private let router = ProviderRouter()

    // MARK: - Built-in personas (the source of truth)

    /// The Studio quiz generator's persona. This constant is the real, default prompt — a
    /// user can override it at `~/OakReader/prompts/quiz.md` (see ``StudioPromptStore``), but
    /// nothing is bundled, so by default this is what runs. `{{difficulty}}` / `{{count}}`
    /// are substituted at call time.
    private static let defaultQuizPersona = """
        You are an expert educator creating study FLASHCARDS from a document. \
        Target this cognitive level: {{difficulty}}. \
        Generate about {{count}} flashcards covering the most important material in the \
        text provided. Ground every card strictly in the text — never invent facts, \
        names, or numbers that aren't supported by it.
        """

    enum GeneratorError: LocalizedError {
        case provider(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .provider(let message): return message
            case .emptyResult: return "The AI didn't return any usable cards. Try again."
            }
        }
    }

    // MARK: - Quiz

    /// A growing snapshot of a quiz being streamed: the cards parsed so far and
    /// the deck title once it has streamed in.
    struct QuizSnapshot: Sendable {
        var title: String?
        var cards: [QuizContent]
    }

    /// Stream a flashcard deck grounded in `source`. Yields a growing snapshot as
    /// each card finishes streaming (so the UI fills card-by-card). Large,
    /// paginated documents are split into page-range chunks generated in
    /// sequence so the whole document is covered and each card cites its page;
    /// small documents take a single pass. Flashcard-only by design.
    func streamQuiz(
        source: StudioSource,
        documentTitle: String,
        params: StudioGenerationParams
    ) -> AsyncThrowingStream<QuizSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prefs = Preferences.shared
                    let providerId = prefs.aiProviderId
                    let model = prefs.aiModel.isEmpty
                        ? (ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? "")
                        : prefs.aiModel
                    let config = ProviderConfig(providerId: providerId, model: model)
                    let svc = try await router.provider(for: config)

                    let chunks = Self.chunk(source, limit: Self.chunkCharLimit)
                    let target = params.amount.count
                    // Spread the requested count across chunks (at least 2 each so
                    // a short tail chunk still earns a card or two).
                    let perChunk = chunks.count <= 1
                        ? target
                        : max(2, Int(ceil(Double(target) / Double(chunks.count))))

                    var allCards: [QuizContent] = []
                    var deckTitle: String?

                    for (idx, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        // Stop once we've satisfied the target across chunks.
                        if chunks.count > 1 && allCards.count >= target { break }
                        let want = chunks.count <= 1
                            ? target
                            : min(perChunk, max(2, target - allCards.count))

                        let (system, user) = Self.quizPrompts(
                            chunk: chunk, documentTitle: documentTitle, params: params,
                            count: want, wantTitle: idx == 0, paginated: source.isPaginated
                        )
                        let stream = svc.sendMessage(
                            messages: [LLMMessage(role: .user, text: user)],
                            model: model,
                            systemPrompt: system,
                            maxTokens: 4096
                        )

                        var raw = ""
                        var lastCount = 0
                        for try await piece in stream {
                            switch piece {
                            case .delta(let delta):
                                raw += delta
                                let cards = QuizCardCodec.cardsFromPartialJSON(raw)
                                if cards.count > lastCount {
                                    lastCount = cards.count
                                    if deckTitle == nil, let t = QuizCardCodec.titleFromJSON(raw), !t.isEmpty {
                                        deckTitle = t
                                    }
                                    continuation.yield(QuizSnapshot(title: deckTitle, cards: allCards + cards))
                                }
                            case .error(let message):
                                throw GeneratorError.provider(message)
                            case .thinking, .toolUse, .toolInputDelta, .finished:
                                break
                            }
                        }

                        // Authoritative parse of this chunk's complete object.
                        let chunkCards: [QuizContent]
                        if let json = Self.extractJSONObject(raw), let deck = QuizCardCodec.deck(fromJSON: json) {
                            chunkCards = deck.cards
                            if (deckTitle ?? "").isEmpty, !deck.title.isEmpty { deckTitle = deck.title }
                        } else {
                            chunkCards = QuizCardCodec.cardsFromPartialJSON(raw)
                        }
                        allCards.append(contentsOf: chunkCards)
                        continuation.yield(QuizSnapshot(title: deckTitle, cards: allCards))
                    }

                    guard !allCards.isEmpty else { throw GeneratorError.emptyResult }
                    continuation.yield(QuizSnapshot(title: deckTitle, cards: allCards))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Split a source into page-range chunks no larger than `limit` characters,
    /// never breaking a page across chunks. A single over-long page becomes its
    /// own chunk rather than being dropped.
    private static func chunk(_ source: StudioSource, limit: Int) -> [SourceChunk] {
        var chunks: [SourceChunk] = []
        var current: [StudioSourcePage] = []
        var length = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current
                .map { $0.number > 0 ? "[Page \($0.number)]\n\($0.text)" : $0.text }
                .joined(separator: "\n\n")
            chunks.append(SourceChunk(pageStart: first.number, pageEnd: last.number, text: text))
            current = []
            length = 0
        }

        for page in source.pages where !page.text.isEmpty {
            if length + page.text.count > limit, !current.isEmpty { flush() }
            current.append(page)
            length += page.text.count
        }
        flush()
        return chunks.isEmpty ? [SourceChunk(pageStart: 0, pageEnd: 0, text: "")] : chunks
    }

    private static func quizPrompts(
        chunk: SourceChunk,
        documentTitle: String,
        params: StudioGenerationParams,
        count: Int,
        wantTitle: Bool,
        paginated: Bool
    ) -> (system: String, user: String) {
        let citeRule: String
        if paginated {
            citeRule = """
                For EVERY card include the source location: "source_page" — the integer \
                page number (shown as [Page N] in the text) the answer is found on — and \
                "source_quote" — a short VERBATIM excerpt (4–12 words) copied exactly from \
                that page that the answer is based on. The page MUST be one actually shown \
                in the text below; never cite a page that isn't present.
                """
        } else {
            citeRule = """
                For EVERY card include "source_quote" — a short VERBATIM excerpt (4–12 \
                words) copied exactly from the text that the answer is based on. Omit \
                "source_page".
                """
        }
        let titleClause = wantTitle
            ? "Include a short \"title\" for the whole deck. "
            : "Set \"title\" to an empty string. "

        // Persona (editable, from prompts/quiz.md) + format contract (fixed, owned here so
        // a user edit can never break QuizCardCodec's JSON parsing).
        let persona = (StudioPromptStore.persona(for: .quiz) ?? Self.defaultQuizPersona)
            .replacingOccurrences(of: "{{difficulty}}", with: params.difficulty.promptPhrase)
            .replacingOccurrences(of: "{{count}}", with: String(count))

        let envelope = """
            \(citeRule)

            Respond with ONLY a single JSON object — no prose, no explanation, no code \
            fences. \(titleClause)EVERY card must be a flashcard (a question on the front, \
            the answer on the back):
            {"title": "<short deck title or empty>", "cards": [
              {"type": "flashcard", "data": {"front": "<question, Markdown>", "back": "<answer, Markdown>", "source_page": <int>, "source_quote": "<verbatim excerpt>"}}
            ]}

            Use ONLY the "flashcard" type. front and back are Markdown. Put one clear \
            question on the front and a concise, complete answer on the back.
            """

        let system = persona + "\n\n" + envelope

        var user = "Document title: \(documentTitle)\n"
        if chunk.pageStart > 0 {
            let range = chunk.pageStart == chunk.pageEnd
                ? "page \(chunk.pageStart)"
                : "pages \(chunk.pageStart)–\(chunk.pageEnd)"
            user += "This excerpt covers \(range) of the document.\n"
        }
        user += "\n"
        let custom = params.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            user += "Additional focus from the user: \(custom)\n\n"
        }
        user += "Source content:\n\n\(chunk.text)"
        return (system, user)
    }

    // MARK: - Response cleanup

    /// Pull the first complete JSON object out of a model response, tolerating
    /// stray prose or ```json code fences around it.
    static func extractJSONObject(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
            s = s.replacingOccurrences(of: "```", with: "")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(s[start...end])
    }
}
