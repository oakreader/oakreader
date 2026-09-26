import Foundation

/// The table behind `oak:N` citation links.
///
/// Every passage the model is shown enters its context already numbered —
///
///     [14] The Transformer follows this overall architecture using stacked self-attention…
///
/// — and the model cites one by linking that number: `[p. 2](oak:14)`. The app resolves the
/// number back to the document, the location, and the verbatim passage text.
///
/// **Why numbers and not a self-describing URL.** The previous protocol had the model write
/// the whole anchor itself — `oak://cite/{citeKey}?page=2&text=<verbatim quote>` — which asked
/// it to do three hard things at once: pick the claim, reproduce the source text exactly, and
/// URL-encode it. It needed ~6 KB of system prompt to police, still produced anchors that
/// failed to highlight when the quote was paraphrased, and put an 80-character URL in the
/// middle of the answer where the renderer had to hide it mid-stream. With a number the model
/// can only ever name a passage we handed it: it cannot misspell a quote, mis-encode a space,
/// or invent a page. This is Dia's `SourcesController` / `url://3` design.
///
/// Ids are stable for the life of a conversation and are persisted beside its transcript, so
/// reopening an old chat still resolves its citations.
final class CitationSourceRegistry: @unchecked Sendable {

    /// One citable passage.
    struct Source: Codable, Sendable, Equatable {
        /// Stable id of the document the passage belongs to. An id, not a cite key:
        /// cite keys are user-editable, and keying on one meant renaming a key had to
        /// rewrite every stored citation in every transcript. Empty means "the open
        /// document", which is all an item without a library row can be.
        var itemId: String
        /// 0-based page index, for paged documents.
        var page: Int?
        /// Seconds into the timeline, for audio/video.
        var time: Double?
        /// Nearest enclosing heading, for documents that have no pages.
        var heading: String?
        /// The passage itself, whitespace-normalized — this is what gets highlighted.
        /// `nil` for a whole-document handle (the model cited the source, not a passage).
        var text: String?
    }

    private let lock = NSLock()
    private var sources: [Int: Source] = [:]
    /// Reverse index so re-showing the same passage in a later turn reuses its number
    /// instead of growing the table on every request.
    private var idsByFingerprint: [String: Int] = [:]
    private var nextID = 1
    private var sessionId: UUID
    private let directory: URL

    init(sessionId: UUID, directory: URL) {
        self.sessionId = sessionId
        self.directory = directory
        load()
    }

    // MARK: - Session lifecycle

    /// Point the registry at a different conversation, loading its table from disk.
    func activate(sessionId: UUID) {
        lock.lock()
        guard self.sessionId != sessionId else { lock.unlock(); return }
        self.sessionId = sessionId
        sources = [:]
        idsByFingerprint = [:]
        nextID = 1
        lock.unlock()
        load()
    }

    // MARK: - Minting & resolution

    /// Mint (or reuse) the number for a passage.
    @discardableResult
    func register(_ source: Source) -> Int {
        let key = fingerprint(source)
        lock.lock()
        defer { lock.unlock() }
        if let existing = idsByFingerprint[key] { return existing }
        let id = nextID
        nextID += 1
        sources[id] = source
        idsByFingerprint[key] = id
        return id
    }

    func source(for id: Int) -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return sources[id]
    }

    private func fingerprint(_ s: Source) -> String {
        // The text alone is not unique (a running header repeats on every page), so the
        // location is part of the identity.
        "\(s.itemId)|\(s.page.map(String.init) ?? "")|\(s.time.map { String(format: "%.3f", $0) } ?? "")|\(s.text ?? "")"
    }

    // MARK: - Numbering a block of source text

    /// Shortest run of characters worth its own number. Anything shorter (a stray line of
    /// page furniture, a one-word heading) is folded into the passage before it, so the
    /// numbers stay sparse enough for the model to read past.
    private static let minPassageChars = 80
    /// Longest passage before it is split at a sentence boundary — a whole-page passage
    /// would highlight as a page-sized blob instead of the evidence.
    private static let maxPassageChars = 800

    /// Number every passage in `text` and register it against `itemId`, returning the text
    /// with `[N]` markers prepended. `page` and `time` locate the whole block; `heading` is
    /// tracked per passage for documents that have neither.
    func numbered(_ text: String, itemId: String, page: Int? = nil, time: Double? = nil) -> String {
        let passages = Self.splitIntoPassages(text)
        guard !passages.isEmpty else { return text }
        var heading: String?
        var out: [String] = []
        out.reserveCapacity(passages.count)
        for passage in passages {
            if let h = Self.markdownHeading(passage) {
                // A heading is not itself worth citing, but it locates what follows.
                heading = h
                out.append(passage)
                continue
            }
            let id = register(Source(
                itemId: itemId,
                page: page,
                time: time,
                heading: heading,
                text: Self.normalized(passage)
            ))
            out.append("[\(id)] \(passage)")
        }
        return out.joined(separator: "\n\n")
    }

    /// Split source text into citable passages: paragraphs, with short fragments folded
    /// into their predecessor and over-long ones cut at a sentence boundary.
    static func splitIntoPassages(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .split(whereSeparator: \.isEmpty)
            .map { $0.joined(separator: "\n") }

        var merged: [String] = []
        for paragraph in paragraphs where !paragraph.isEmpty {
            if paragraph.count < minPassageChars, markdownHeading(paragraph) == nil,
               let last = merged.last, markdownHeading(last) == nil {
                merged[merged.count - 1] = last + "\n" + paragraph
            } else {
                merged.append(paragraph)
            }
        }
        return merged.flatMap { $0.count > maxPassageChars ? splitLongPassage($0) : [$0] }
    }

    /// Cut an over-long paragraph into ≤`maxPassageChars` chunks at sentence boundaries,
    /// falling back to a hard cut when a "sentence" is itself longer than the limit.
    private static func splitLongPassage(_ paragraph: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let sentence = String(paragraph[range])
            if current.count + sentence.count > maxPassageChars, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current += sentence
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return chunks.isEmpty ? [paragraph] : chunks
    }

    /// The text of a markdown ATX heading (`## Batch Endpoints`), or nil.
    static func markdownHeading(_ passage: String) -> String? {
        guard passage.hasPrefix("#"), !passage.contains("\n") else { return nil }
        let stripped = passage.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? nil : stripped
    }

    /// Collapse the layout newlines and runs of spaces that PDF and HTML extraction leave
    /// behind, so the stored passage is the contiguous run the highlighters search for.
    static func normalized(_ passage: String) -> String {
        passage
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Persistence

    private var fileURL: URL {
        directory.appendingPathComponent("\(sessionId.uuidString).sources.json")
    }

    /// Write the table beside the conversation transcript. Cheap enough to call after each
    /// request: a long chat holds a few hundred passages.
    func save() {
        lock.lock()
        let snapshot = sources
        let url = fileURL
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        // JSON object keys must be strings; the ids are Ints.
        let keyed = Dictionary(uniqueKeysWithValues: snapshot.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(keyed) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        let url = fileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Source].self, from: data)
        else { return }
        lock.lock()
        defer { lock.unlock() }
        for (key, source) in decoded {
            guard let id = Int(key) else { continue }
            sources[id] = source
            idsByFingerprint[fingerprint(source)] = id
            nextID = max(nextID, id + 1)
        }
    }

    /// Delete the table for a conversation that is being removed.
    static func deleteTable(sessionId: UUID, directory: URL) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(sessionId.uuidString).sources.json"))
    }
}
