import Foundation

/// Chat-session metadata, indexed by the core; transcripts are JSONL files here.
///
/// The split is older than the migration and worth keeping: a transcript is an
/// append-only log, which a relational row models badly. So the core owns the
/// index and this owns the files — including `snippet`, which reads a bounded
/// prefix of one to produce the history list's teaser.
struct ConversationService {
    // MARK: - Fetch

    /// Sessions for one document, newest first, each with its teaser line.
    func fetchSessions(forItemId itemId: String) async -> [ConversationMeta] {
        await fetch(itemId: itemId)
    }

    /// Library-wide sessions (no document), newest first.
    func fetchLibrarySessions() async -> [ConversationMeta] {
        await fetch(itemId: nil)
    }

    private func fetch(itemId: String?) async -> [ConversationMeta] {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.conversationsList,
                params: RPC.ConversationsListParams(itemId: itemId),
                as: RPC.ConversationsListResult.self)
            // The teaser comes from the transcript on disk, so it is filled in
            // here rather than travelling over the protocol.
            return (result.conversations ?? []).map {
                ConversationMeta(wire: $0, snippet: snippet(forId: $0.id))
            }
        } catch {
            Log.error(Log.store, "conversations/list failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Snippet

    /// Minimal projection of a persisted JSONL turn — just enough to find the
    /// first user message for the history list's teaser line.
    private struct SnippetTurn: Decodable {
        let role: String
        let content: String
    }

    /// Extracts a short teaser (first user message) from a session's JSONL file.
    /// Reads only a bounded prefix so a long conversation doesn't cost a full file read.
    private func snippet(forId idString: String) -> String {
        guard let id = UUID(uuidString: idString) else { return "" }
        let url = CatalogDatabase.chatFileURL(sessionId: id)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        // The first user turn is almost always the first line; 64 KB covers it.
        let prefix = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let text = String(data: prefix, encoding: .utf8) else { return "" }

        // Only consider complete lines (drop a possibly-truncated trailing line).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let completeLines = text.hasSuffix("\n") ? lines : lines.dropLast()

        let decoder = JSONDecoder()
        for line in completeLines {
            guard let data = line.data(using: .utf8),
                  let turn = try? decoder.decode(SnippetTurn.self, from: data),
                  turn.role == "user" else { continue }
            return Self.cleanSnippet(turn.content)
        }
        return ""
    }

    /// Strips inline skill tags and collapses whitespace into a single tidy line.
    private static func cleanSnippet(_ raw: String) -> String {
        var s = raw
        // Drop leading `[[skill:…]]` / `[[ref:…]]` tags used for durable UI rendering.
        while let open = s.range(of: "[["), let close = s.range(of: "]]"),
              open.lowerBound == s.startIndex || s[s.startIndex..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s = String(s[close.upperBound...])
        }
        return s
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Create

    @discardableResult
    func createSession(id: UUID, title: String, itemId: String?) async -> ConversationMeta {
        let now = Date().iso8601String
        let wire = CatalogConversation(
            id: id.uuidString, itemId: itemId, title: title,
            messageCount: 0, createdAt: now, updatedAt: now)
        do {
            try await NodeBackend.shared.call(
                RPC.Method.conversationsCreate,
                params: RPC.ConversationsCreateParams(conversation: wire))
        } catch {
            Log.error(Log.store, "conversations/create failed: \(error.localizedDescription)")
        }
        return ConversationMeta(wire: wire, snippet: "")
    }

    // MARK: - Update

    func updateSession(id: UUID, title: String, messageCount: Int) async {
        do {
            try await NodeBackend.shared.call(
                RPC.Method.conversationsUpdate,
                params: RPC.ConversationsUpdateParams(
                    id: id.uuidString, title: title,
                    messageCount: messageCount, at: Date().iso8601String))
        } catch {
            Log.error(Log.store, "conversations/update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete

    func deleteSession(id: UUID) async {
        do {
            try await NodeBackend.shared.call(
                RPC.Method.conversationsDelete,
                params: RPC.ConversationsDeleteParams(id: id.uuidString))
        } catch {
            Log.error(Log.store, "conversations/delete failed: \(error.localizedDescription)")
        }
    }
}
