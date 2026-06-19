import Foundation

/// Scans persisted AI chat history for `oak://cite/{key}` links and counts or rewrites
/// them when a cite key changes.
///
/// Chat turns are stored as flat JSONL files in `~/OakReader/chats/{sessionId}.jsonl`
/// (see `CatalogDatabase.chatsDirectory`). The `oak://cite/...` URLs appear verbatim inside
/// each turn's markdown body, and none of their characters need JSON escaping, so we can
/// match and replace directly on the raw file text without parsing each line.
///
/// All methods do plain file I/O and hold no state, so callers run them off the main thread.
enum CiteLinkRewriter {

    /// Outcome of a rewrite pass.
    struct RewriteResult {
        /// Number of `oak://cite/` links successfully rewritten (only counts links in files
        /// that were written back without error).
        let linksRewritten: Int
        /// Number of chat files that matched but could not be written back.
        let failedFiles: Int
        /// Session ids (derived from the JSONL filenames) whose content was changed — so a
        /// live chat view showing one of them can reload from disk.
        let affectedSessions: [UUID]

        static let empty = RewriteResult(linksRewritten: 0, failedFiles: 0, affectedSessions: [])
    }

    /// Count how many `oak://cite/{key}` links across all stored chats reference `key`.
    static func countReferences(toKey key: String) -> Int {
        guard !key.isEmpty, let regex = boundaryRegex(forKey: key) else { return 0 }
        let needle = "oak://cite/\(key)"
        var total = 0
        forEachChatFile { _, text in
            guard text.contains(needle) else { return }
            total += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        return total
    }

    /// Rewrite every `oak://cite/{oldKey}` link to `oak://cite/{newKey}` across all stored
    /// chats, in place. Writes that fail are reported in `failedFiles` rather than silently
    /// counted as updated.
    @discardableResult
    static func rewrite(from oldKey: String, to newKey: String) -> RewriteResult {
        guard oldKey != newKey, !oldKey.isEmpty, let regex = boundaryRegex(forKey: oldKey) else {
            return .empty
        }
        let needle = "oak://cite/\(oldKey)"
        let template = NSRegularExpression.escapedTemplate(for: "oak://cite/\(newKey)")
        var links = 0
        var failed = 0
        var sessions: [UUID] = []

        forEachChatFile { url, text in
            guard text.contains(needle) else { return }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.numberOfMatches(in: text, range: range)
            guard matches > 0 else { return }

            let rewritten = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
            do {
                try rewritten.write(to: url, atomically: true, encoding: .utf8)
                links += matches
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                    sessions.append(id)
                }
            } catch {
                failed += 1
            }
        }
        return RewriteResult(linksRewritten: links, failedFiles: failed, affectedSessions: sessions)
    }

    // MARK: - Internal

    /// Read each `*.jsonl` chat file and hand its URL + contents to `body`.
    private static func forEachChatFile(_ body: (URL, String) -> Void) {
        let dir = CatalogDatabase.chatsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            body(file, text)
        }
    }

    /// `oak://cite/{key}` where the key is NOT followed by another key character, so that
    /// e.g. `vaswani2017` does not match inside `vaswani2017a`. Cite keys may contain
    /// letters, digits, and `_ . : -`.
    private static func boundaryRegex(forKey key: String) -> NSRegularExpression? {
        let pattern = "oak://cite/" + NSRegularExpression.escapedPattern(for: key) + "(?![A-Za-z0-9_.:\\-])"
        return try? NSRegularExpression(pattern: pattern)
    }
}

extension Notification.Name {
    /// Posted (on the main thread) after cite-key links are rewritten in chat history.
    /// `userInfo["sessions"]` carries the affected `[UUID]` session ids.
    static let oakCiteKeysRewritten = Notification.Name("oakCiteKeysRewritten")
}
