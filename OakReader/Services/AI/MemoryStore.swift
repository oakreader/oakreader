import Foundation

// MARK: - Memory Fact

/// A single discrete memory — the unit the whole system operates on (mem0-style),
/// instead of one prose blob that gets rewritten and drifts. Stored one-per-line
/// as JSONL so the files stay human-legible and grep-able.
struct MemoryFact: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var text: String
    var createdAt: String      // ISO 8601
    var updatedAt: String
    var source: Source
    /// Pinned facts are never auto-edited or auto-deleted by background reflection.
    var pinned: Bool

    enum Source: String, Codable {
        case user        // typed/edited by the user in the manager
        case remember    // saved via the `remember` tool (explicit user statement)
        case reflection  // inferred by background reflection
    }

    init(text: String, source: Source, pinned: Bool = false) {
        let now = ISO8601DateFormatter().string(from: Date())
        self.id = MemoryStore.newID()
        self.text = text
        self.createdAt = now
        self.updatedAt = now
        self.source = source
        // User/remember facts are pinned by default — the human asserted them, so
        // reflection must not quietly overwrite or drop them.
        self.pinned = pinned || source == .user || source == .remember
    }
}

// MARK: - Scope

/// Which memory a fact belongs to: the global user profile, or one document.
enum MemoryScope: Equatable, Hashable {
    case user
    case item(String)   // itemId

    var label: String {
        switch self {
        case .user: return "user"
        case .item(let id): return "item:\(id)"
        }
    }

    var factsURL: URL {
        switch self {
        case .user: return CatalogDatabase.agentProfileFactsURL
        case .item(let id): return CatalogDatabase.chatBriefFactsURL(itemId: id)
        }
    }

    /// Legacy prose file to import from on first load (nil once both are gone).
    var legacyURL: URL? {
        switch self {
        case .user: return CatalogDatabase.agentUserFileURL
        case .item(let id): return CatalogDatabase.chatBriefURL(itemId: id)
        }
    }
}

// MARK: - Operation (from reflection)

/// One edit decided by background reflection — mem0's ADD / UPDATE / DELETE / NOOP.
struct MemoryOp: Codable {
    let op: String          // "ADD" | "UPDATE" | "DELETE" | "NOOP"
    let id: String?         // target fact id for UPDATE/DELETE
    let text: String?       // new text for ADD/UPDATE
}

// MARK: - Audit log entry

struct MemoryLogEntry: Codable, Identifiable {
    let id: String
    let ts: String
    let scope: String
    let op: String          // ADD | UPDATE | DELETE
    let factId: String
    let before: String?
    let after: String?
}

// MARK: - Store

/// Stateless persistence + mutation for memory facts. All writes are full-file
/// rewrites (the files are tiny) and every structural change appends to the audit
/// log, so you can always see what the agent changed and why.
enum MemoryStore {

    static func newID() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<6).map { _ in chars.randomElement()! })
    }

    // MARK: Load / Save

    /// Load facts for a scope. On first access, imports any legacy prose file.
    static func load(_ scope: MemoryScope) -> [MemoryFact] {
        let url = scope.factsURL
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            return decode(data)
        }
        // Migrate a legacy `.md` prose file (bullets → facts) once.
        if let migrated = importLegacy(scope), !migrated.isEmpty {
            save(migrated, scope: scope)
            return migrated
        }
        return []
    }

    static func save(_ facts: [MemoryFact], scope: MemoryScope) {
        let url = scope.factsURL
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
    static func rendered(_ scope: MemoryScope) -> String {
        let facts = load(scope)
        guard !facts.isEmpty else { return "" }
        return facts.map { "- \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Mutations (user-facing)

    @discardableResult
    static func add(_ text: String, source: MemoryFact.Source, scope: MemoryScope) -> MemoryFact {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var facts = load(scope)
        let fact = MemoryFact(text: trimmed, source: source)
        facts.append(fact)
        save(facts, scope: scope)
        appendLog(scope: scope, op: "ADD", factId: fact.id, before: nil, after: trimmed)
        return fact
    }

    /// True if an identical fact already exists (cheap dedup for the remember tool).
    static func contains(_ text: String, scope: MemoryScope) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return load(scope).contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
    }

    /// Edit a fact's text (from the manager UI). Logs an UPDATE.
    static func update(id: String, text: String, scope: MemoryScope) {
        var facts = load(scope)
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        let before = facts[idx].text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != before else { return }
        facts[idx].text = trimmed
        facts[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
        save(facts, scope: scope)
        appendLog(scope: scope, op: "UPDATE", factId: id, before: before, after: trimmed)
    }

    /// Delete a fact (from the manager UI). Logs a DELETE.
    static func delete(id: String, scope: MemoryScope) {
        var facts = load(scope)
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        let removed = facts.remove(at: idx)
        save(facts, scope: scope)
        appendLog(scope: scope, op: "DELETE", factId: id, before: removed.text, after: nil)
    }

    /// Pin / unpin a fact. Pinned facts are protected from background reflection.
    static func setPinned(_ pinned: Bool, id: String, scope: MemoryScope) {
        var facts = load(scope)
        guard let idx = facts.firstIndex(where: { $0.id == id }), facts[idx].pinned != pinned else { return }
        facts[idx].pinned = pinned
        save(facts, scope: scope)
    }

    // MARK: Apply reflection ops

    /// Apply a batch of reflection operations. Pinned facts (and user/remember
    /// sources) are protected: they are never deleted and only updated in place,
    /// never dropped. Each applied op is written to the audit log. Returns the
    /// number of facts actually changed (so the UI can surface "memory updated").
    @discardableResult
    static func apply(_ ops: [MemoryOp], scope: MemoryScope, maxFacts: Int) -> Int {
        var facts = load(scope)
        var byId = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        let now = ISO8601DateFormatter().string(from: Date())
        var changes = 0

        for op in ops {
            switch op.op.uppercased() {
            case "ADD":
                guard let text = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                // Skip exact dupes.
                if facts.contains(where: { $0.text.lowercased() == text.lowercased() }) { continue }
                let fact = MemoryFact(text: text, source: .reflection)
                facts.append(fact)
                byId[fact.id] = fact
                appendLog(scope: scope, op: "ADD", factId: fact.id, before: nil, after: text)
                changes += 1

            case "UPDATE":
                guard let id = op.id, var fact = byId[id],
                      let text = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      let idx = facts.firstIndex(where: { $0.id == id }) else { continue }
                let before = fact.text
                guard before != text else { continue }
                fact.text = text
                fact.updatedAt = now
                facts[idx] = fact
                byId[id] = fact
                appendLog(scope: scope, op: "UPDATE", factId: id, before: before, after: text)
                changes += 1

            case "DELETE":
                guard let id = op.id, let fact = byId[id],
                      let idx = facts.firstIndex(where: { $0.id == id }) else { continue }
                // Protect human-asserted / pinned facts from auto-deletion.
                if fact.pinned { continue }
                facts.remove(at: idx)
                byId[id] = nil
                appendLog(scope: scope, op: "DELETE", factId: id, before: fact.text, after: nil)
                changes += 1

            default:
                continue   // NOOP / unknown
            }
        }

        // Cap size: evict oldest *unpinned reflection* facts past the budget.
        if facts.count > maxFacts {
            var removable = facts.enumerated()
                .filter { !$0.element.pinned }
                .sorted { $0.element.updatedAt < $1.element.updatedAt }
            while facts.count > maxFacts, let oldest = removable.first {
                if let idx = facts.firstIndex(where: { $0.id == oldest.element.id }) {
                    appendLog(scope: scope, op: "DELETE", factId: oldest.element.id, before: oldest.element.text, after: nil)
                    facts.remove(at: idx)
                }
                removable.removeFirst()
            }
        }

        save(facts, scope: scope)
        return changes
    }

    // MARK: Audit log

    static func appendLog(scope: MemoryScope, op: String, factId: String, before: String?, after: String?) {
        let entry = MemoryLogEntry(
            id: newID(),
            ts: ISO8601DateFormatter().string(from: Date()),
            scope: scope.label,
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

    /// Recent audit entries for a scope, newest first.
    static func recentLog(scope: MemoryScope, limit: Int = 50) -> [MemoryLogEntry] {
        let url = CatalogDatabase.agentMemoryLogURL
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let entries = content.components(separatedBy: "\n").compactMap { line -> MemoryLogEntry? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(MemoryLogEntry.self, from: d)
        }
        return entries.filter { $0.scope == scope.label }.reversed().prefix(limit).map { $0 }
    }

    // MARK: Legacy import

    /// Parse a legacy prose `.md` file (markdown bullets) into facts.
    private static func importLegacy(_ scope: MemoryScope) -> [MemoryFact]? {
        guard let url = scope.legacyURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var facts: [MemoryFact] = []
        var inRemembered = false
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                inRemembered = line.lowercased().contains("remembered")
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            // Skip empty template bullets like "- Name:" with nothing after.
            guard !text.isEmpty, !text.hasSuffix(":") else { continue }
            facts.append(MemoryFact(text: text, source: inRemembered ? .remember : .user))
        }
        return facts
    }
}
