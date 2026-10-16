import Foundation

/// What a conversation is about.
///
/// Three cases rather than two optionals: a chat belongs to a document, or to
/// a collection, or to the library at large, and they are mutually exclusive.
/// Mirrors `ConversationScope` in the core.
enum ConversationScope: Equatable {
    case item(String)
    case collection(String)
    case library
}

/// Chat-session metadata, indexed by the core.
///
/// A transcript is an append-only log, which a relational row models badly,
/// so it is a pi session file beside the index: the core writes it, and this
/// reads the start of one to produce the history list's teaser (`snippet`).
struct ConversationService {
    // MARK: - Fetch

    /// Sessions in one scope, newest first, each with its teaser line.
    func fetchSessions(in scope: ConversationScope) async -> [ConversationMeta] {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.conversationsList,
                params: RPC.ConversationsListParams(
                    itemId: scope.itemId, collectionId: scope.collectionId),
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

    /// The first user message of a session file, as the user typed it.
    ///
    /// Reads a bounded prefix. The prompt's system message comes first and
    /// can be large; 4 MB covers it and the first user message in practice.
    private func snippet(forId idString: String) -> String {
        guard let id = UUID(uuidString: idString) else { return "" }
        let url = CatalogDatabase.chatFileURL(sessionId: id)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let prefix = (try? handle.read(upToCount: 4 * 1024 * 1024)) ?? Data()
        // Only complete lines: the last one may be cut off.
        var lines = prefix.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if prefix.last != UInt8(ascii: "\n") { lines = lines.dropLast() }

        let decoder = JSONDecoder()
        var firstUser: (id: String, text: String)?
        for line in lines {
            guard let entry = try? decoder.decode(JSONValue.self, from: Data(line)) else { continue }
            if let user = firstUser {
                // The display entry right after it holds the typed text.
                if entry["customType"]?.stringValue == PiSession.displayType,
                   entry["data"]?["targetId"]?.stringValue == user.id,
                   let typed = entry["data"]?["content"]?.stringValue {
                    return Self.cleanSnippet(typed)
                }
                return Self.cleanSnippet(user.text)
            }
            if entry["type"]?.stringValue == "message", let m = entry["message"],
               PiMessage.role(m) == "user", let entryId = entry["id"]?.stringValue {
                firstUser = (entryId, PiMessage.text(m))
            }
        }
        return firstUser.map { Self.cleanSnippet($0.text) } ?? ""
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
    func createSession(id: UUID, title: String, scope: ConversationScope) async -> ConversationMeta {
        let now = Date().iso8601String
        let wire = CatalogConversation(
            id: id.uuidString, itemId: scope.itemId, collectionId: scope.collectionId,
            title: title, messageCount: 0, createdAt: now, updatedAt: now)
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

// MARK: - Scope → wire

extension ConversationScope {
    /// The document this scope names, if it names one.
    var itemId: String? {
        if case .item(let id) = self { return id }
        return nil
    }

    /// The collection this scope names, if it names one.
    var collectionId: String? {
        if case .collection(let id) = self { return id }
        return nil
    }
}
