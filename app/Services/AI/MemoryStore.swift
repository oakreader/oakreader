import Foundation

// MARK: - Memory Fact

/// A single discrete memory — the unit the whole system operates on (ChatGPT
/// "saved memories" style), instead of one prose blob that gets rewritten and
/// drifts. Stored one-per-line as JSONL so the file stays human-legible and
/// grep-able. There is exactly one store: the user's global profile.
struct MemoryFact: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var text: String
    var createdAt: String      // ISO 8601
    var updatedAt: String
    var source: Source

    enum Source: String, Codable {
        case user        // typed/edited by the user in the manager
        case remember    // saved by the model via the `manage_memory` tool
    }

    init(text: String, source: Source) {
        let now = ISO8601DateFormatter().string(from: Date())
        self.id = MemoryStore.newID()
        self.text = text
        self.createdAt = now
        self.updatedAt = now
        self.source = source
    }
}

// MARK: - Audit log entry

struct MemoryLogEntry: Codable, Identifiable {
    let id: String
    let ts: String
    let op: String          // ADD | UPDATE | DELETE
    let factId: String
    let before: String?
    let after: String?
}

// MARK: - Store

/// Stateless persistence + mutation for the global user-memory facts. All writes
/// are full-file rewrites (the file is tiny) and every structural change appends
/// to the audit log, so you can always see what changed and why.
enum MemoryStore {

    /// Where the discrete facts live (one JSON per line).
    private static var factsURL: URL { CatalogDatabase.agentProfileFactsURL }

    static func newID() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<6).map { _ in chars.randomElement()! })
    }

    // MARK: Load / Save

    /// Load all facts.
    static func load() -> [MemoryFact] {
        guard let data = try? Data(contentsOf: factsURL), !data.isEmpty else { return [] }
        return decode(data)
    }

    static func save(_ facts: [MemoryFact]) {
        let url = factsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        let lines = facts.compactMap { fact -> String? in
            guard let data = try? encoder.encode(fact) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func decode(_ data: Data) -> [MemoryFact] {
        let decoder = JSONDecoder()
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(MemoryFact.self, from: d)
        }
    }

    // MARK: Rendering (for prompt injection)

    /// Bullet list of fact texts, or empty string if none.
    static func rendered() -> String {
        let facts = load()
        guard !facts.isEmpty else { return "" }
        return facts.map { "- \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Mutations

    @discardableResult
    static func add(_ text: String, source: MemoryFact.Source) -> MemoryFact {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var facts = load()
        let fact = MemoryFact(text: trimmed, source: source)
        facts.append(fact)
        save(facts)
        appendLog(op: "ADD", factId: fact.id, before: nil, after: trimmed)
        return fact
    }

    /// True if an identical fact already exists (cheap dedup for the tool).
    static func contains(_ text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return load().contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
    }

    /// Edit a fact's text. Logs an UPDATE.
    static func update(id: String, text: String) {
        var facts = load()
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        let before = facts[idx].text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != before else { return }
        facts[idx].text = trimmed
        facts[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
        save(facts)
        appendLog(op: "UPDATE", factId: id, before: before, after: trimmed)
    }

    /// Delete a fact. Logs a DELETE.
    static func delete(id: String) {
        var facts = load()
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        let removed = facts.remove(at: idx)
        save(facts)
        appendLog(op: "DELETE", factId: id, before: removed.text, after: nil)
    }

    // MARK: Audit log

    static func appendLog(op: String, factId: String, before: String?, after: String?) {
        let entry = MemoryLogEntry(
            id: newID(),
            ts: ISO8601DateFormatter().string(from: Date()),
            op: op,
            factId: factId,
            before: before,
            after: after
        )
        guard let data = try? JSONEncoder().encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = CatalogDatabase.agentMemoryLogURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Recent audit entries, newest first.
    static func recentLog(limit: Int = 50) -> [MemoryLogEntry] {
        let url = CatalogDatabase.agentMemoryLogURL
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let entries = content.components(separatedBy: "\n").compactMap { line -> MemoryLogEntry? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(MemoryLogEntry.self, from: d)
        }
        return entries.reversed().prefix(limit).map { $0 }
    }
}
