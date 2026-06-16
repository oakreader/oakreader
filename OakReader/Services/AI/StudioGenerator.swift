import Foundation
import OakAgent

/// One-shot, source-grounded generation of AI Studio artifacts. Mirrors the
/// streaming pattern in `TranslationViewModel`: resolve the user's configured
/// provider, send a single system+user prompt, accumulate the streamed text.
///
/// Each kind has its own method. Phase 1 ships `generateQuiz`; mind map / deck /
/// audio land in later phases.
struct StudioGenerator {
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

    /// Stream a flashcard deck grounded in `sourceText`. Yields a growing
    /// snapshot as each card finishes streaming (so the UI fills card-by-card),
    /// ending with an authoritative final snapshot parsed from the complete JSON.
    /// Flashcard-only by design — one question/answer card type.
    func streamQuiz(
        sourceText: String,
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
                    let (system, user) = Self.quizPrompts(
                        sourceText: sourceText, documentTitle: documentTitle, params: params
                    )

                    let svc = try await router.provider(for: config)
                    let stream = svc.sendMessage(
                        messages: [LLMMessage(role: .user, text: user)],
                        model: model,
                        systemPrompt: system,
                        maxTokens: 4096
                    )

                    var raw = ""
                    var lastCount = 0
                    for try await chunk in stream {
                        switch chunk {
                        case .delta(let delta):
                            raw += delta
                            let cards = QuizCardCodec.cardsFromPartialJSON(raw)
                            if cards.count > lastCount {
                                lastCount = cards.count
                                continuation.yield(QuizSnapshot(title: QuizCardCodec.titleFromJSON(raw), cards: cards))
                            }
                        case .error(let message):
                            throw GeneratorError.provider(message)
                        case .thinking, .toolUse, .toolInputDelta, .finished:
                            break
                        }
                    }

                    // Authoritative final parse from the complete object.
                    let finalCards: [QuizContent]
                    let finalTitle: String?
                    if let json = Self.extractJSONObject(raw), let deck = QuizCardCodec.deck(fromJSON: json) {
                        finalCards = deck.cards
                        finalTitle = deck.title.isEmpty ? nil : deck.title
                    } else {
                        finalCards = QuizCardCodec.cardsFromPartialJSON(raw)
                        finalTitle = QuizCardCodec.titleFromJSON(raw)
                    }
                    guard !finalCards.isEmpty else { throw GeneratorError.emptyResult }
                    continuation.yield(QuizSnapshot(title: finalTitle, cards: finalCards))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func quizPrompts(
        sourceText: String,
        documentTitle: String,
        params: StudioGenerationParams
    ) -> (system: String, user: String) {
        let system = """
            You are an expert educator creating study FLASHCARDS from a single document. \
            Target this cognitive level: \(params.difficulty.promptPhrase). \
            Generate about \(params.amount.count) flashcards covering the document's most \
            important material. Ground every card strictly in the document — never invent \
            facts, names, or numbers that aren't supported by the text.

            Respond with ONLY a single JSON object — no prose, no explanation, no code \
            fences. EVERY card must be a flashcard (a question on the front, the answer on \
            the back):
            {"title": "<short deck title>", "cards": [
              {"type": "flashcard", "data": {"front": "<question, Markdown>", "back": "<answer, Markdown>"}}
            ]}

            Use ONLY the "flashcard" type. All text fields are Markdown. Put one clear \
            question on the front and a concise, complete answer on the back.
            """

        var user = "Document title: \(documentTitle)\n\n"
        let custom = params.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            user += "Additional focus from the user: \(custom)\n\n"
        }
        user += "Source content:\n\n\(sourceText)"
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
            the point actually is.

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
