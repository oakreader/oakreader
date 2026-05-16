import Foundation
import OakAgent

// MARK: - Limits

/// Budget constants for memory files (inspired by OpenClaw's bootstrapMaxChars: 20,000).
/// We keep ours tighter since these are learning-focused, not general-purpose.
private enum MemoryLimits {
    /// Max characters for MEMORY.md (≈6,000 tokens at 3.3 chars/token).
    static let memoryMaxChars = 20_000
    /// Max entries per section in MEMORY.md.
    static let memoryMaxEntriesPerSection = 30
    /// Max characters for USER.md.
    static let userMaxChars = 5000
    /// Max entries per section in USER.md.
    static let userMaxEntriesPerSection = 10
}

// MARK: - Update Memory Tool

/// Allows the agent to append observations to ~/OakReader/agent/MEMORY.md
/// after quiz sessions or learning discussions.
/// Enforces a 4000-char / 10-entries-per-section cap. Oldest entries evicted first.
struct UpdateMemoryTool: AgentTool {
    let name = "update_memory"
    let description = """
        Update the user's cognitive map — their evolving mental models, \
        learning frontier, misconceptions, and growth trajectory. \
        This is NOT a knowledge base. It tracks HOW the user thinks and \
        how their understanding changes over time. \
        Each entry must be ONE concise line (max 120 chars). \
        Oldest entries are evicted when limits are reached.
        """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "section": [
                "type": "string",
                "description": "Section to append to.",
                "enum": [
                    "Current Mental Models",
                    "Active Edges (learning frontier)",
                    "Misconceptions (active)",
                    "Resolved Misconceptions",
                    "Connections Discovered",
                    "Cognitive Patterns",
                    "Growth Trajectory"
                ]
            ],
            "entry": [
                "type": "string",
                "description": "One-line observation. Max 120 chars. Format: '[YYYY-MM-DD] fact — source' or just the fact."
            ]
        ],
        "required": ["section", "entry"]
    ]

    var category: ToolCategory { .write }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let section = input["section"], !section.isEmpty else {
            return ToolOutput(content: "Error: 'section' parameter is required.")
        }
        guard var entry = input["entry"], !entry.isEmpty else {
            return ToolOutput(content: "Error: 'entry' parameter is required.")
        }

        // Truncate entry to 120 chars
        if entry.count > 120 {
            entry = String(entry.prefix(117)) + "..."
        }

        let memoryURL = CatalogDatabase.agentMemoryFileURL
        try FileManager.default.createDirectory(at: CatalogDatabase.agentDirectory, withIntermediateDirectories: true)

        var content: String
        if FileManager.default.fileExists(atPath: memoryURL.path) {
            content = try String(contentsOf: memoryURL, encoding: .utf8)
        } else {
            content = Self.defaultTemplate
        }

        // Insert entry into section
        content = MemoryFileEditor.insertEntry(
            into: content,
            section: section,
            entry: entry,
            maxEntriesPerSection: MemoryLimits.memoryMaxEntriesPerSection
        )

        // Enforce total file size — trim oldest entries from largest section
        content = MemoryFileEditor.enforceCharLimit(content, maxChars: MemoryLimits.memoryMaxChars)

        try content.write(to: memoryURL, atomically: true, encoding: .utf8)

        let charCount = content.count
        return ToolOutput(content: "Memory updated [\(charCount)/\(MemoryLimits.memoryMaxChars) chars]: added to \"\(section)\".")
    }

    private static let defaultTemplate = """
    # Cognitive Map

    ## Current Mental Models

    ## Active Edges (learning frontier)

    ## Misconceptions (active)

    ## Resolved Misconceptions

    ## Connections Discovered

    ## Cognitive Patterns

    ## Growth Trajectory
    """
}

// MARK: - Update User Profile Tool

/// Allows the agent to update specific fields in ~/OakReader/agent/USER.md.
/// Enforces a 2000-char / 6-entries-per-section cap.
struct UpdateUserProfileTool: AgentTool {
    let name = "update_user_profile"
    let description = """
        Update the user's evolving learning profile. Record background, \
        learning goals, cognition targets, strengths, and weak points. \
        Auto-update when you discover: what the user does professionally, \
        what they want to learn, what mental models they're building, \
        or how their abilities are growing. One-line entries (max 80 chars). \
        Oldest entries evicted when section is full.
        """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "section": [
                "type": "string",
                "description": "Section to update.",
                "enum": [
                    "Background",
                    "Learning Goals",
                    "Cognition Targets",
                    "Domains & Interests",
                    "Known Strengths",
                    "Known Weak Points",
                    "Learning Style",
                    "Preferences"
                ]
            ],
            "entry": [
                "type": "string",
                "description": "One-line fact to add. Max 80 chars."
            ]
        ],
        "required": ["section", "entry"]
    ]

    var category: ToolCategory { .write }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let section = input["section"], !section.isEmpty else {
            return ToolOutput(content: "Error: 'section' parameter is required.")
        }
        guard var entry = input["entry"], !entry.isEmpty else {
            return ToolOutput(content: "Error: 'entry' parameter is required.")
        }

        // Truncate to 80 chars
        if entry.count > 80 {
            entry = String(entry.prefix(77)) + "..."
        }

        let userURL = CatalogDatabase.agentUserFileURL
        try FileManager.default.createDirectory(at: CatalogDatabase.agentDirectory, withIntermediateDirectories: true)

        var content: String
        if FileManager.default.fileExists(atPath: userURL.path) {
            content = try String(contentsOf: userURL, encoding: .utf8)
        } else {
            content = Self.defaultTemplate
        }

        content = MemoryFileEditor.insertEntry(
            into: content,
            section: section,
            entry: entry,
            maxEntriesPerSection: MemoryLimits.userMaxEntriesPerSection
        )

        content = MemoryFileEditor.enforceCharLimit(content, maxChars: MemoryLimits.userMaxChars)

        try content.write(to: userURL, atomically: true, encoding: .utf8)

        let charCount = content.count
        return ToolOutput(content: "Profile updated [\(charCount)/\(MemoryLimits.userMaxChars) chars]: added to \"\(section)\".")
    }

    private static let defaultTemplate = """
    # User Profile

    ## Identity
    - Name:
    - Language: English

    ## Background

    ## Learning Goals

    ## Cognition Targets

    ## Domains & Interests

    ## Known Strengths

    ## Known Weak Points

    ## Learning Style

    ## Preferences
    - Response style: concise
    - Tone: direct
    """
}

// MARK: - Learning Log Entry (JSONL record)

/// A single learning event, stored as one JSON line in daily JSONL files.
struct LearningLogEntry: Codable {
    let timestamp: String   // ISO 8601
    let type: String        // confusion, struggle, insight, breakthrough, question, correction
    let subject: String     // topic tag: "economics", "machine-learning"
    let entry: String       // what happened
    let document: String?   // source document (optional)
}

// MARK: - Daily Learning Log Tool

/// Appends structured JSONL entries to ~/OakReader/agent/memory/YYYY-MM-DD.jsonl.
/// One JSON object per line — fast to query by field, no regex needed.
/// Unlike MEMORY.md (curated, always loaded), daily logs are only loaded for today+yesterday.
struct LogLearningTool: AgentTool {
    let name = "log_learning"
    let description = """
        Log a learning event to today's daily log (JSONL). Use during sessions to record: \
        confusion ("didn't understand X"), struggle ("took 3 attempts to get Y"), \
        insight ("realized X connects to Y"), or breakthrough ("finally grasped Z"). \
        Daily logs are raw material — write naturally, no size pressure. \
        Always include a subject tag for searchability. \
        These feed into monthly/yearly summaries over time.
        """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "type": [
                "type": "string",
                "description": "Type of learning event.",
                "enum": ["confusion", "struggle", "insight", "breakthrough", "question", "correction"]
            ],
            "subject": [
                "type": "string",
                // swiftlint:disable:next line_length
                "description": "Use the document's collection name or tag from the user's library. Lowercase, hyphenated. If multiple apply, pick the most specific."
            ],
            "entry": [
                "type": "string",
                "description": "What happened. Be specific — include the concept, document, and context."
            ],
            "document": [
                "type": "string",
                "description": "Document name this relates to (optional)."
            ]
        ],
        "required": ["type", "subject", "entry"]
    ]

    var category: ToolCategory { .write }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let type = input["type"], !type.isEmpty else {
            return ToolOutput(content: "Error: 'type' parameter is required.")
        }
        guard let subject = input["subject"], !subject.isEmpty else {
            return ToolOutput(content: "Error: 'subject' parameter is required.")
        }
        guard let entry = input["entry"], !entry.isEmpty else {
            return ToolOutput(content: "Error: 'entry' parameter is required.")
        }

        let logsDir = CatalogDatabase.agentMemoryLogsDirectory
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let logURL = CatalogDatabase.agentDailyLogURL()
        let now = Date()

        let record = LearningLogEntry(
            timestamp: ISO8601DateFormatter().string(from: now),
            type: type,
            subject: subject.lowercased().replacingOccurrences(of: " ", with: "-"),
            entry: entry,
            document: input["document"]
        )

        let jsonData = try JSONEncoder().encode(record)
        guard var jsonLine = String(data: jsonData, encoding: .utf8) else {
            return ToolOutput(content: "Error: failed to encode entry.")
        }
        jsonLine += "\n"

        // Append to file
        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            handle.write(jsonLine.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try jsonLine.write(to: logURL, atomically: true, encoding: .utf8)
        }

        return ToolOutput(content: "Logged [\(type)] #\(record.subject) to daily log.")
    }
}

// MARK: - Promote to Monthly Summary

/// Compresses daily logs into a monthly summary. Called by the agent at month boundaries
/// or when daily logs accumulate enough signal.
struct PromoteMemoryTool: AgentTool {
    let name = "promote_memory"
    let description = """
        Summarize and promote patterns from daily logs into monthly/yearly summaries \
        or into MEMORY.md. Use when you notice recurring patterns across multiple days: \
        repeated confusions become "Active Weak Points", repeated insights become \
        "Cognition Milestones", growth patterns become "Growth Log" entries. \
        Also use at month boundaries to write a monthly learning summary.
        """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "target": [
                "type": "string",
                "description": "Where to promote to.",
                "enum": ["monthly", "yearly", "memory"]
            ],
            "summary": [
                "type": "string",
                "description": "The compressed summary or pattern to record. For monthly: 2-3 sentence overview. For memory: one-line durable fact."
            ]
        ],
        "required": ["target", "summary"]
    ]

    var category: ToolCategory { .write }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let target = input["target"], !target.isEmpty else {
            return ToolOutput(content: "Error: 'target' parameter is required.")
        }
        guard let summary = input["summary"], !summary.isEmpty else {
            return ToolOutput(content: "Error: 'summary' parameter is required.")
        }

        let logsDir = CatalogDatabase.agentMemoryLogsDirectory
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let now = Date()

        switch target {
        case "monthly":
            let url = CatalogDatabase.agentMonthlyLogURL(date: now)
            var content: String
            if FileManager.default.fileExists(atPath: url.path) {
                content = try String(contentsOf: url, encoding: .utf8)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM (MMMM)"
                content = "# \(formatter.string(from: now))\n\n"
            }
            content += "- \(summary)\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput(content: "Promoted to monthly summary.")

        case "yearly":
            let url = CatalogDatabase.agentYearlyLogURL(date: now)
            var content: String
            if FileManager.default.fileExists(atPath: url.path) {
                content = try String(contentsOf: url, encoding: .utf8)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy"
                content = "# \(formatter.string(from: now)) — Learning Trajectory\n\n"
            }
            content += "- \(summary)\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput(content: "Promoted to yearly trajectory.")

        case "memory":
            // Delegate to the standard memory update flow
            let memoryURL = CatalogDatabase.agentMemoryFileURL
            var content: String
            if FileManager.default.fileExists(atPath: memoryURL.path) {
                content = try String(contentsOf: memoryURL, encoding: .utf8)
            } else {
                content = "# Cognitive Map\n\n## Growth Trajectory\n"
            }
            content = MemoryFileEditor.insertEntry(
                into: content, section: "Growth Trajectory", entry: summary,
                maxEntriesPerSection: MemoryLimits.memoryMaxEntriesPerSection
            )
            content = MemoryFileEditor.enforceCharLimit(content, maxChars: MemoryLimits.memoryMaxChars)
            try content.write(to: memoryURL, atomically: true, encoding: .utf8)
            return ToolOutput(content: "Promoted to cognitive map (Growth Trajectory).")

        default:
            return ToolOutput(content: "Error: target must be 'monthly', 'yearly', or 'memory'.")
        }
    }
}

// MARK: - Search Learning Logs

/// Searches across all daily JSONL logs with structured filtering.
/// Fast: parses JSON fields directly instead of regex on markdown.
struct SearchLearningLogTool: AgentTool {
    let name = "search_learning_log"
    let description = """
        Search past learning logs by subject, type, or keyword. \
        Use to find: all confusion about a subject, past insights on a topic, \
        or when the user last studied something. \
        Searches across all daily JSONL log files (newest first).
        """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Keyword to search in entry text (e.g., 'backpropagation', 'supply curve'). Case-insensitive."
            ],
            "subject": [
                "type": "string",
                "description": "Filter by subject (collection name or tag from user's library). Prefix match supported."
            ],
            "type_filter": [
                "type": "string",
                "description": "Filter by entry type.",
                "enum": ["confusion", "struggle", "insight", "breakthrough", "question", "correction"]
            ],
            "limit": [
                "type": "string",
                "description": "Max results to return. Default: 20."
            ]
        ],
        "required": []
    ]

    var category: ToolCategory { .readOnly }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        let query = input["query"]?.lowercased()
        let subjectFilter = input["subject"]?.lowercased()
        let typeFilter = input["type_filter"]
        let limit = Int(input["limit"] ?? "20") ?? 20

        // Need at least one filter
        guard query != nil || subjectFilter != nil || typeFilter != nil else {
            return ToolOutput(content: "Error: provide at least one of 'query', 'subject', or 'type_filter'.")
        }

        let logsDir = CatalogDatabase.agentMemoryLogsDirectory
        guard FileManager.default.fileExists(atPath: logsDir.path) else {
            return ToolOutput(content: "No learning logs found yet.")
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "jsonl" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) // newest first
        else {
            return ToolOutput(content: "No learning logs found.")
        }

        let decoder = JSONDecoder()
        var results: [String] = []

        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let date = file.deletingPathExtension().lastPathComponent // "2026-05-16"

            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let entry = try? decoder.decode(LearningLogEntry.self, from: data) else {
                    continue
                }

                // Apply filters
                if let typeFilter, entry.type != typeFilter { continue }
                if let subjectFilter, !entry.subject.hasPrefix(subjectFilter)
                    && entry.subject != subjectFilter { continue }
                if let query, !entry.entry.lowercased().contains(query)
                    && !entry.subject.contains(query) { continue }

                // Format result
                let time = String(entry.timestamp.suffix(from: entry.timestamp.index(entry.timestamp.startIndex, offsetBy: 11)).prefix(5))
                let doc = entry.document.map { " — \($0)" } ?? ""
                results.append("[\(date) \(time)] [\(entry.type)] #\(entry.subject) \(entry.entry)\(doc)")

                if results.count >= limit { break }
            }
            if results.count >= limit { break }
        }

        if results.isEmpty {
            let filters = [query.map { "query=\"\($0)\"" }, subjectFilter.map { "subject=\($0)" }, typeFilter.map { "type=\($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
            return ToolOutput(content: "No entries found (\(filters)).")
        }

        return ToolOutput(content: "Found \(results.count) entries:\n" + results.joined(separator: "\n"))
    }
}

// MARK: - Concept Map Tool

/// Reads or updates the concept map for a given collection.
/// Each collection has its own concept wiki tracking: what concepts exist,
/// user's mastery level per concept, and concept relationships.
struct UpdateConceptMapTool: AgentTool {
    let name = "update_concept_map"
    let description = """
        Update the concept map for the current document's collection. \
        Add new concepts discovered in documents, update mastery levels \
        after quiz/discussion, or add relationships between concepts. \
        Each collection maintains its own concept vocabulary.
        """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "collection": [
                "type": "string",
                "description": "Collection name (from document context)."
            ],
            "action": [
                "type": "string",
                "description": "What to do.",
                "enum": ["add_concept", "update_mastery", "add_relationship", "add_gap"]
            ],
            "concept": [
                "type": "string",
                "description": "Concept name."
            ],
            "definition": [
                "type": "string",
                "description": "One-line definition (for add_concept)."
            ],
            "mastery": [
                "type": "string",
                "description": "Mastery level.",
                "enum": ["unseen", "encountered", "partial", "solid", "deep"]
            ],
            "source": [
                "type": "string",
                "description": "Document and page where concept appears (for add_concept)."
            ],
            "related_to": [
                "type": "string",
                "description": "Other concept name (for add_relationship)."
            ],
            "relationship": [
                "type": "string",
                "description": "Relationship type (for add_relationship).",
                "enum": [
                    "prerequisite", "part-of", "contrasts-with",
                    "enables", "example-of", "related"
                ]
            ]
        ],
        "required": ["collection", "action", "concept"]
    ]

    var category: ToolCategory { .write }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let collection = input["collection"], !collection.isEmpty else {
            return ToolOutput(content: "Error: 'collection' is required.")
        }
        guard let action = input["action"], !action.isEmpty else {
            return ToolOutput(content: "Error: 'action' is required.")
        }
        guard let concept = input["concept"], !concept.isEmpty else {
            return ToolOutput(content: "Error: 'concept' is required.")
        }

        let conceptsDir = CatalogDatabase.agentConceptsDirectory
        try FileManager.default.createDirectory(at: conceptsDir, withIntermediateDirectories: true)

        let mapURL = CatalogDatabase.agentConceptMapURL(collectionName: collection)

        var content: String
        if FileManager.default.fileExists(atPath: mapURL.path) {
            content = try String(contentsOf: mapURL, encoding: .utf8)
        } else {
            content = "# Concept Map: \(collection)\n\n## Concepts\n\n## Relationships\n\n## User's Current Frontier\n\n## Gaps\n"
        }

        let masteryIcon: [String: String] = [
            "unseen": "🔴", "encountered": "🟡", "partial": "🟠",
            "solid": "🟢", "deep": "🔵"
        ]

        switch action {
        case "add_concept":
            let level = input["mastery"] ?? "unseen"
            let icon = masteryIcon[level] ?? "🔴"
            let def = input["definition"] ?? ""
            let src = input["source"].map { " (source: \($0))" } ?? ""
            let entry = "- \(icon) **\(concept)** — \(def)\(src)"

            // Check if concept already exists
            if content.contains("**\(concept)**") {
                return ToolOutput(content: "Concept '\(concept)' already exists. Use update_mastery to change level.")
            }

            content = MemoryFileEditor.insertEntry(
                into: content, section: "Concepts", entry: String(entry.dropFirst(2)),
                maxEntriesPerSection: 100
            )

            // If unseen, also add to Gaps
            if level == "unseen" {
                content = MemoryFileEditor.insertEntry(
                    into: content, section: "Gaps", entry: concept,
                    maxEntriesPerSection: 20
                )
            }

        case "update_mastery":
            guard let level = input["mastery"] else {
                return ToolOutput(content: "Error: 'mastery' is required for update_mastery.")
            }
            let icon = masteryIcon[level] ?? "🔴"

            // Replace the mastery icon for this concept
            let pattern = "(🔴|🟡|🟠|🟢|🔵) \\*\\*\(NSRegularExpression.escapedPattern(for: concept))\\*\\*"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                let range = Range(match.range(at: 1), in: content)!
                content.replaceSubrange(range, with: icon)
            }

            // Update frontier: add if partial/encountered, remove if solid/deep
            if level == "encountered" || level == "partial" {
                if !content.contains("## User's Current Frontier") ||
                    !content.components(separatedBy: "\n").contains(where: {
                        $0.contains(concept) && $0.contains("Frontier")
                    }) {
                    content = MemoryFileEditor.insertEntry(
                        into: content, section: "User's Current Frontier", entry: concept,
                        maxEntriesPerSection: 15
                    )
                }
            }

            // Remove from Gaps if no longer unseen
            if level != "unseen" {
                var lines = content.components(separatedBy: "\n")
                lines.removeAll { line in
                    let inGaps = false // simplified: remove concept from Gaps section
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed == "- \(concept)" && content.contains("## Gaps")
                }
                // More precise: remove from Gaps section only
                if let gapsIdx = lines.firstIndex(where: { $0.contains("## Gaps") }) {
                    var i = gapsIdx + 1
                    while i < lines.count {
                        if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("## ") { break }
                        if lines[i].trimmingCharacters(in: .whitespaces) == "- \(concept)" {
                            lines.remove(at: i)
                            break
                        }
                        i += 1
                    }
                }
                content = lines.joined(separator: "\n")
            }

        case "add_relationship":
            guard let relatedTo = input["related_to"], !relatedTo.isEmpty else {
                return ToolOutput(content: "Error: 'related_to' is required for add_relationship.")
            }
            let relType = input["relationship"] ?? "related"
            let entry = "\(concept) → \(relatedTo) (\(relType))"
            content = MemoryFileEditor.insertEntry(
                into: content, section: "Relationships", entry: entry,
                maxEntriesPerSection: 50
            )

        case "add_gap":
            content = MemoryFileEditor.insertEntry(
                into: content, section: "Gaps", entry: concept,
                maxEntriesPerSection: 20
            )

        default:
            return ToolOutput(content: "Error: unknown action '\(action)'.")
        }

        try content.write(to: mapURL, atomically: true, encoding: .utf8)
        return ToolOutput(content: "Concept map '\(collection)' updated: \(action) '\(concept)'.")
    }
}

/// Reads the concept map for a collection so the LLM can review it.
struct ReadConceptMapTool: AgentTool {
    let name = "read_concept_map"
    let description = """
        Read the concept map for a collection. Returns all concepts, \
        mastery levels, relationships, frontier, and gaps. \
        Use to understand what the user knows before generating quizzes \
        or deciding what to explain next.
        """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "collection": [
                "type": "string",
                "description": "Collection name to read concept map for."
            ]
        ],
        "required": ["collection"]
    ]

    var category: ToolCategory { .readOnly }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let collection = input["collection"], !collection.isEmpty else {
            return ToolOutput(content: "Error: 'collection' is required.")
        }

        let mapURL = CatalogDatabase.agentConceptMapURL(collectionName: collection)
        guard FileManager.default.fileExists(atPath: mapURL.path),
              let content = try? String(contentsOf: mapURL, encoding: .utf8) else {
            return ToolOutput(content: "No concept map exists for '\(collection)' yet.")
        }

        return ToolOutput(content: content)
    }
}

// MARK: - Memory File Editor (shared logic)

/// Stateless helpers for inserting entries into markdown section files with size limits.
enum MemoryFileEditor {

    /// Insert an entry under a `## Section` heading. If the section has more entries
    /// than `maxEntriesPerSection`, the oldest (topmost) entry in that section is removed.
    static func insertEntry(
        into content: String,
        section: String,
        entry: String,
        maxEntriesPerSection: Int
    ) -> String {
        var lines = content.components(separatedBy: "\n")
        let sectionMarker = "## \(section)"

        // Find section start
        guard let sectionIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == sectionMarker }) else {
            // Section not found — append at end
            lines.append("")
            lines.append(sectionMarker)
            lines.append("- \(entry)")
            return lines.joined(separator: "\n")
        }

        // Find range of entries in this section (lines starting with "- " between this heading and next heading)
        let afterSection = sectionIdx + 1
        var entryIndices: [Int] = []
        for i in afterSection..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break } // next section
            if trimmed.hasPrefix("- ") {
                entryIndices.append(i)
            }
        }

        // Find insertion point (after last entry in section, or after heading + comments)
        let insertAt: Int
        if let lastEntry = entryIndices.last {
            insertAt = lastEntry + 1
        } else {
            // No entries yet — skip heading, blank lines, and HTML comments
            var cursor = afterSection
            while cursor < lines.count {
                let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("<!--") || trimmed.hasSuffix("-->") {
                    cursor += 1
                } else {
                    break
                }
            }
            insertAt = cursor
        }

        // Insert new entry
        lines.insert("- \(entry)", at: insertAt)
        entryIndices.append(insertAt) // track for count

        // Evict oldest entries if over limit (oldest = first entry in section)
        let currentCount = entryIndices.count + 1 // +1 for the one we just added... recalculate
        // Recalculate actual entries after insertion
        var actualEntryIndices: [Int] = []
        for i in (sectionIdx + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }
            if trimmed.hasPrefix("- ") {
                actualEntryIndices.append(i)
            }
        }

        while actualEntryIndices.count > maxEntriesPerSection {
            // Remove the oldest (first) entry
            let removeIdx = actualEntryIndices.removeFirst()
            lines.remove(at: removeIdx)
            // Adjust remaining indices
            actualEntryIndices = actualEntryIndices.map { $0 - 1 }
        }

        return lines.joined(separator: "\n")
    }

    /// If total content exceeds `maxChars`, remove the oldest entry from the section
    /// with the most entries, repeating until under budget.
    static func enforceCharLimit(_ content: String, maxChars: Int) -> String {
        var lines = content.components(separatedBy: "\n")

        while lines.joined(separator: "\n").count > maxChars {
            // Find section with most entries
            var bestEntryCount = 0
            var bestFirstEntry = 0

            var i = 0
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
                    var entryCount = 0
                    var firstEntry = -1
                    var j = i + 1
                    while j < lines.count {
                        let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("## ") { break }
                        if trimmed.hasPrefix("- ") {
                            if firstEntry == -1 { firstEntry = j }
                            entryCount += 1
                        }
                        j += 1
                    }
                    if entryCount > bestEntryCount && firstEntry >= 0 {
                        bestEntryCount = entryCount
                        bestFirstEntry = firstEntry
                    }
                    i = j
                } else {
                    i += 1
                }
            }

            // No entries to remove — can't shrink further
            guard bestEntryCount > 0 else { break }

            // Remove oldest entry (first in the largest section)
            lines.remove(at: bestFirstEntry)
        }

        return lines.joined(separator: "\n")
    }
}
