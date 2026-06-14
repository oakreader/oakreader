import Foundation
import OakAgent

/// Background "subconscious" memory writer (mem0-style).
///
/// After a conversation settles, this runs off the hot path to keep two stores
/// current — by *discrete per-fact operations* (ADD / UPDATE / DELETE / NOOP)
/// against a `MemoryStore`, NOT by rewriting a prose blob. Untouched facts are
/// never re-written, so the stores can't drift, and every change is auditable:
///
///   1. User profile (`MemoryScope.user`) — durable facts about the person.
///      Always injected into prompts.
///   2. Per-document brief (`MemoryScope.item`) — continuity points for one
///      document. Injected only when that document is open.
///
/// Pinned / user-asserted facts are protected from auto-deletion (handled in
/// `MemoryStore.apply`). Everything is fail-soft: any error leaves the stores
/// untouched and never disrupts the chat that triggered it.
struct MemoryReflectionService {
    /// Cheap/fast model config (the caller passes its research/background config).
    let config: ProviderConfig
    /// System prompt for profile fact extraction (defaults to the built-in).
    var profilePrompt: String = MemoryReflectionService.defaultProfileSystem
    /// System prompt for the per-document brief (defaults to the built-in).
    var briefPrompt: String = MemoryReflectionService.defaultBriefSystem

    private static let maxProfileFacts = 40
    private static let maxBriefFacts = 20

    // MARK: - Profile

    /// Returns the number of facts changed (for surfacing "memory updated").
    @discardableResult
    func consolidateProfile(recentTurns: [Turn]) async -> Int {
        await reflect(scope: .user, system: profilePrompt, recentTurns: recentTurns, maxFacts: Self.maxProfileFacts)
    }

    // MARK: - Per-document brief

    @discardableResult
    func updateItemBrief(itemId: String, recentTurns: [Turn]) async -> Int {
        await reflect(scope: .item(itemId), system: briefPrompt, recentTurns: recentTurns, maxFacts: Self.maxBriefFacts)
    }

    // MARK: - Core reflection loop

    private func reflect(scope: MemoryScope, system: String, recentTurns: [Turn], maxFacts: Int) async -> Int {
        let transcript = Self.transcript(from: recentTurns, maxChars: 6_000)
        guard !transcript.isEmpty else { return 0 }

        let existing = MemoryStore.load(scope)
        let existingBlock = existing.isEmpty
            ? "(no facts yet)"
            : existing.map { "[\($0.id)]\($0.pinned ? " (pinned)" : "") \($0.text)" }.joined(separator: "\n")

        let user = """
            <existing-facts>
            \(existingBlock)
            </existing-facts>

            <recent-conversation>
            \(transcript)
            </recent-conversation>
            """

        guard let raw = await Self.complete(system: system, user: user, config: config) else { return 0 }
        let ops = Self.parseOps(raw)
        guard !ops.isEmpty else { return 0 }
        return MemoryStore.apply(ops, scope: scope, maxFacts: maxFacts)
    }

    // MARK: - System prompts (built-in defaults; overridable via Settings)

    static let defaultProfileSystem = """
        You maintain a list of discrete, durable FACTS about a user of a \
        document-reading / study app, used to personalize how an AI tutor talks to them.

        You are given the existing facts (each tagged with an [id], some marked \
        "(pinned)") and a recent conversation. Decide what to change as a list of \
        operations. Output ONLY a JSON array, e.g.:
        [{"op":"ADD","text":"..."},{"op":"UPDATE","id":"ab12","text":"..."},{"op":"DELETE","id":"cd34"}]

        Operations:
        - ADD: a genuinely new durable fact not already covered. One crisp sentence.
        - UPDATE: correct or enrich an existing fact — give its id and the full new text.
        - DELETE: an existing fact that is now wrong or outdated — give its id.
        - (omit anything unchanged; an empty array [] means no change.)

        Rules:
        - Keep ONLY durable, person-level facts: who they are, background, what \
        they're trying to learn or do, domains of interest, explicit response/tone \
        preferences. NOT document-specific details.
        - Phrase tentatively when inferred. Do NOT invent diagnoses of their \
        "misconceptions" or "cognitive patterns".
        - Never DELETE a "(pinned)" fact. Prefer few operations; most turns need none.
        - Output ONLY the JSON array — no prose, no code fences.
        """

    static let defaultBriefSystem = """
        You maintain a list of discrete continuity FACTS about ONE document, so an \
        AI tutor can pick up where it left off next time the user opens it.

        You are given the existing facts (each tagged with an [id], some "(pinned)") \
        and a recent conversation about this document. Output ONLY a JSON array of \
        operations:
        [{"op":"ADD","text":"..."},{"op":"UPDATE","id":"ab12","text":"..."},{"op":"DELETE","id":"cd34"}]

        Operations: ADD a new point, UPDATE an existing one (id + full new text), \
        DELETE one that's stale (id). Omit unchanged facts; [] means no change.

        Capture: what the document is about (in the user's framing), what's been \
        discussed or worked through, and open questions / next steps. Keep each fact \
        one short line. Never DELETE a "(pinned)" fact. Prefer few operations.
        Output ONLY the JSON array — no prose, no code fences.
        """

    // MARK: - Op parsing

    /// Parse the model's JSON array of operations, tolerating a stray code fence
    /// or surrounding prose.
    static func parseOps(_ raw: String) -> [MemoryOp] {
        let cleaned = Self.cleaned(raw)
        // Find the first '[' … matching ']' span to be robust to chatter.
        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]"), start < end else {
            return []
        }
        let json = String(cleaned[start...end])
        guard let data = json.data(using: .utf8),
              let ops = try? JSONDecoder().decode([MemoryOp].self, from: data) else {
            return []
        }
        return ops
    }

    // MARK: - One-shot completion

    /// Run a single no-tools completion via an ephemeral session in a temp dir.
    private static func complete(system: String, user: String, config: ProviderConfig) async -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("oak-reflect-\(UUID().uuidString)", isDirectory: true)
        let session = AgentSession(chatsDirectory: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var streamed = ""
        var finalText: String?
        do {
            let stream = await session.send(
                userContent: user,
                attachments: [],
                history: [],
                sessionId: UUID(),
                config: config,
                systemPrompt: system,
                tools: nil,
                toolContext: nil,
                maxIterations: 1
            )
            for try await event in stream {
                switch event {
                case .delta(let d):
                    streamed += d
                case .finished(let turn) where turn.role == .assistant:
                    finalText = turn.content
                default:
                    break
                }
            }
        } catch {
            return nil
        }

        let result = (finalText ?? streamed).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    // MARK: - Helpers

    /// Strip an accidental ```…``` wrapper and trim.
    private static func cleaned(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fence = s.range(of: "```", options: .backwards) {
                s = String(s[..<fence.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Render the most recent turns as a plain transcript, capped to `maxChars`
    /// (keeping the tail — the most recent exchange).
    private static func transcript(from turns: [Turn], maxChars: Int) -> String {
        var lines: [String] = []
        for turn in turns {
            let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let who: String
            switch turn.role {
            case .user: who = "User"
            case .assistant: who = "Assistant"
            case .system: continue
            }
            lines.append("\(who): \(text)")
        }
        var transcript = lines.joined(separator: "\n\n")
        if transcript.count > maxChars {
            transcript = String(transcript.suffix(maxChars))
        }
        return transcript
    }
}
