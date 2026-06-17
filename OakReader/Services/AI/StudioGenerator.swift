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
/// Each kind has its own method. Phase 1 ships `generateQuiz`; mind map / deck /
/// audio land in later phases.
struct StudioGenerator {
    /// Page text budget per generation call. Large docs are split into several
    /// chunks of roughly this size so the whole document is covered (not just
    /// the first ~10 pages) and each chunk's cards cite pages within its range.
    private static let chunkCharLimit = 7_000
    private let router = ProviderRouter()

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

        let system = """
            You are an expert educator creating study FLASHCARDS from a document. \
            Target this cognitive level: \(params.difficulty.promptPhrase). \
            Generate about \(count) flashcards covering the most important material in the \
            text provided. Ground every card strictly in the text — never invent facts, \
            names, or numbers that aren't supported by it.

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

    // MARK: - Mind Map

    /// Stream a mind map grounded in `sourceText`, as an indented bullet outline
    /// (Mind Elixir's plaintext format: one top-level bullet = the central topic,
    /// two-space nesting for branches). Yields the accumulating outline per line
    /// so the map fills in live, ending with the final outline.
    func streamMindmap(
        sourceText: String,
        documentTitle: String,
        params: StudioGenerationParams
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prefs = Preferences.shared
                    let providerId = prefs.aiProviderId
                    let model = prefs.aiModel.isEmpty
                        ? (ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? "")
                        : prefs.aiModel
                    let config = ProviderConfig(providerId: providerId, model: model)
                    let (system, user) = Self.mindmapPrompts(
                        sourceText: sourceText, documentTitle: documentTitle, params: params
                    )

                    let svc = try await router.provider(for: config)
                    let stream = svc.sendMessage(
                        messages: [LLMMessage(role: .user, text: user)],
                        model: model,
                        systemPrompt: system,
                        maxTokens: 2048
                    )

                    var raw = ""
                    var lastLines = -1
                    for try await chunk in stream {
                        switch chunk {
                        case .delta(let delta):
                            raw += delta
                            // Yield once per completed line (≈ one node) to keep
                            // the live re-render cadence sane.
                            let lines = raw.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                            if lines > lastLines {
                                lastLines = lines
                                continuation.yield(Self.stripCodeFences(raw))
                            }
                        case .error(let message):
                            throw GeneratorError.provider(message)
                        case .thinking, .toolUse, .toolInputDelta, .finished:
                            break
                        }
                    }

                    let final = Self.stripCodeFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !final.isEmpty else { throw GeneratorError.emptyResult }
                    continuation.yield(final)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func mindmapPrompts(
        sourceText: String,
        documentTitle: String,
        params: StudioGenerationParams
    ) -> (system: String, user: String) {
        let detail: String
        switch params.amount {
        case .fewer: detail = "Keep it high-level: main themes and their key points only."
        case .standard: detail = "Balance breadth and depth across the document."
        case .more: detail = "Be thorough: include sub-points and supporting details."
        }

        let system = """
            You are an expert at distilling a document into a MIND MAP for a reader who \
            wants to actually understand it — not a table of contents. \(detail) Ground \
            every node strictly in the document; never invent content.

            STRUCTURE: organize around the document's central topic, its key claims, and \
            the evidence, examples, or caveats that support each claim — the load-bearing \
            ideas, not a chapter list.

            NODES: each node is a short phrase (a few words) carrying a SPECIFIC, concrete \
            point — a name, number, term, finding, or claim. Never use vague bucket labels \
            like "Background", "Overview", "Details", or "Issues" on their own; say what \
            the point actually is. When a point is inherently mathematical, you may write \
            inline LaTeX between single dollar signs (e.g. $E=mc^2$); it renders as math.

            SOURCE ANCHORS: for every LEAF node (one with no children), append the exact \
            passage it comes from, copied VERBATIM from the source, wrapped in ⟪ ⟫ — 4 to \
            15 words, enough to locate it in the document. Do NOT anchor branch nodes that \
            have children.

            Respond with ONLY the outline — no prose, no code fences, no '#' headings. \
            Use EXACTLY ONE top-level bullet for the central topic, then nest branches and \
            sub-branches with two-space indentation:
            - <central topic>
              - <key claim or theme>
                - <specific point> ⟪verbatim source quote⟫
                - <specific point> ⟪verbatim source quote⟫
              - <key claim or theme>
                - <specific point> ⟪verbatim source quote⟫
            """

        var user = "Document title: \(documentTitle)\n\n"
        let custom = params.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { user += "Additional focus from the user: \(custom)\n\n" }
        user += "Source content:\n\n\(sourceText)"
        return (system, user)
    }

    // MARK: - Core one-shot call

    /// Send a single system+user prompt to the user's configured chat provider
    /// and return the fully-accumulated text response.
    private func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let prefs = Preferences.shared
        let providerId = prefs.aiProviderId
        let model = prefs.aiModel.isEmpty
            ? (ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? "")
            : prefs.aiModel
        let config = ProviderConfig(providerId: providerId, model: model)

        let svc = try await router.provider(for: config)
        let stream = svc.sendMessage(
            messages: [LLMMessage(role: .user, text: user)],
            model: model,
            systemPrompt: system,
            maxTokens: maxTokens
        )

        var response = ""
        for try await chunk in stream {
            switch chunk {
            case .delta(let delta):
                response += delta
            case .error(let message):
                throw GeneratorError.provider(message)
            case .thinking, .toolUse, .toolInputDelta, .finished:
                break
            }
        }
        return response
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

    /// Strip surrounding ```/```markdown code fences from a model response.
    static func stripCodeFences(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// The central topic of a mind-map body, whichever format it's in: a Mind
    /// Elixir JSON object (`{ "nodeData": { "topic": … } }`, once the map has been
    /// hand-edited) or the streamed bullet outline. Falls back to `nil`.
    static func titleFromBody(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            if let data = trimmed.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let nodeData = root["nodeData"] as? [String: Any],
               let topic = nodeData["topic"] as? String {
                let title = stripAnchor(topic)
                return title.isEmpty ? nil : title
            }
            return nil
        }
        return titleFromOutline(trimmed)
    }

    /// The central topic of an outline — the first `# Heading` or the first
    /// top-level `-`/`*` bullet.
    static func titleFromOutline(_ outline: String) -> String? {
        for line in outline.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return stripAnchor(String(t.dropFirst(2))) }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return stripAnchor(String(t.dropFirst(2))) }
        }
        return nil
    }

    /// Strip a trailing `⟪…⟫` source anchor (and surrounding whitespace) off a node label.
    static func stripAnchor(_ s: String) -> String {
        guard let open = s.firstIndex(of: "⟪") else {
            return s.trimmingCharacters(in: .whitespaces)
        }
        return String(s[..<open]).trimmingCharacters(in: .whitespaces)
    }
}
