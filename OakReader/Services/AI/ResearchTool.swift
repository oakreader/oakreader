import Foundation
import OakAgent

/// A research **subagent**: runs its own nested, read-only agent loop over the
/// library (full-text search + document reading) and returns only a cited
/// synthesis plus a deterministic source list. The verbose search/read iterations
/// stay in the child's isolated context, keeping the main conversation clean — the
/// "context multiplication" pattern used by Claude Code and Amp.
///
/// Use it for deep questions that span many documents; a single quick lookup
/// should call `search_content` directly instead (a subagent has real cost and
/// latency: it makes several LLM calls of its own).
struct ResearchTool: AgentTool, Sendable {
    let name = "research"
    let category: ToolCategory = .readOnly
    let description = """
        Delegate a deep, multi-document research question to a focused research \
        subagent over the user's library. The subagent iteratively searches the \
        full text, reads the most relevant passages, and returns a concise synthesis \
        with citations plus a list of the sources it used. Prefer this for \
        broad/synthetic questions ("what does my library say about X across papers", \
        "compare how these sources treat Y"). For a single fact or a quick "do I have \
        anything on Z", call search_content directly instead — this tool is slower and \
        more expensive because it runs its own agent loop. Returns a written answer \
        with oak:// citations followed by a Sources section.
        """

    /// Full-text search service shared with the parent (read-only use here).
    let searchService: FTSIndexService
    /// LLM provider/model config for the child loop (typically a cheaper/faster model).
    let config: ProviderConfig
    /// GROUNDED scope: when set, the subagent's search is physically restricted to
    /// this collection's members (catalog id / UUID string).
    var scopeCollectionId: String?
    /// Optional progress sink: receives short human-readable status while the
    /// subagent runs (e.g. "Searching: attention", "Reading: items read Smith2021").
    var onActivity: (@Sendable (String) -> Void)?

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "question": [
                    "type": "string",
                    "description":
                        "The research question to investigate against the user's library."
                ]
            ],
            "required": ["question"]
        ]
    }

    private static let systemPrompt = """
        You are a research assistant working over the user's personal document library. \
        Answer the question using ONLY evidence found in the library — do not rely on prior knowledge.

        Method:
        1. Decompose the question into sub-topics.
        2. Use `search_content` to find relevant passages (refine your keywords and search again \
           if results are thin or off-target; vary terms across a few queries).
        3. Use the `oak` tool to read the most promising documents at their cited pages \
           (e.g. `items read <citeKey> --pages 3-6`).
        4. Synthesize a concise, well-structured answer.

        Citations are required: back every claim with an inline citation in the form \
        `oak://cite/{citeKey}?page=N` so the answer links to the exact source page. \
        Do not append your own sources list — that is generated for you. \
        If the library contains nothing relevant, say so plainly rather than inventing an answer.
        """

    /// Thread-safe log of every passage the subagent retrieved.
    private actor RetrievalLog {
        private(set) var passages: [FTSSearchTool.CitedPassage] = []
        func add(_ newPassages: [FTSSearchTool.CitedPassage]) {
            passages.append(contentsOf: newPassages)
        }
    }

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let question = input["question"], !question.isEmpty else {
            return .error("Missing required parameter: question")
        }

        // Isolated, ephemeral session directory so research loops never clutter the
        // user's saved chat history.
        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oak-research-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDir) }

        let child = AgentSession(chatsDirectory: sessionDir)
        let log = RetrievalLog()

        // Restricted toolset: search + read only. The search tool reports its
        // structured results into the log so we can build the Sources list
        // deterministically. Notably NOT the research tool itself (no recursion).
        var search = FTSSearchTool(service: searchService)
        search.scopeCollectionId = scopeCollectionId
        search.onResults = { @Sendable passages in
            Task { await log.add(passages) }
        }
        let childTools: [any AgentTool] = [search, OakCLITool()]

        // A toolContext is mandatory — AgentSession silently drops tool calls when it
        // is nil. Read-only access scoped to the app data directory.
        let childContext = ToolExecutionContext(
            workingDirectory: sessionDir,
            allowedPaths: [CatalogDatabase.dataDirectory]
        )

        onActivity?("Researching…")

        let stream = await child.send(
            userContent: question,
            attachments: [],
            history: [],
            sessionId: UUID(),
            config: config,
            systemPrompt: scopeCollectionId != nil
                ? Self.systemPrompt + "\n\nSCOPE: search is restricted to the user's active collection — every result already belongs to it. If it contains nothing relevant, say so plainly."
                : Self.systemPrompt,
            tools: childTools,
            toolContext: childContext,
            maxIterations: 8
        )

        // The synthesis is the last assistant turn (the one emitted with no further
        // tool calls). Surface progress from each tool start as we go.
        var answer = ""
        var sawTool = false
        do {
            for try await event in stream {
                switch event {
                case .toolUseStarted(let record):
                    sawTool = true
                    onActivity?(Self.activity(for: record))
                case .delta:
                    if sawTool { onActivity?("Synthesizing…"); sawTool = false }
                case .finished(let turn) where turn.role == .assistant:
                    answer = turn.content
                default:
                    break
                }
            }
        } catch {
            return .error("Research subagent failed: \(error.localizedDescription)")
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success("The research subagent did not produce an answer.")
        }

        let sources = await sourcesSection(answer: trimmed, log: log)
        return .success(trimmed + sources)
    }

    // MARK: - Progress

    private static func activity(for record: ToolUseRecord) -> String {
        switch record.name {
        case "search_content":
            return "Searching: \(record.input["query"] ?? "")"
        case "oak":
            return "Reading: \(record.input["command"] ?? "")"
        default:
            return "Working…"
        }
    }

    // MARK: - Deterministic source list

    /// Build a `### Sources` section from the passages actually retrieved, preferring
    /// those whose citeKey the model cited in its answer. This is generated by the
    /// tool (not the model), so it can't list a source that was never retrieved.
    private func sourcesSection(answer: String, log: RetrievalLog) async -> String {
        let passages = await log.passages
        guard !passages.isEmpty else { return "" }

        var title: [String: String] = [:]
        var pages: [String: Set<Int>] = [:]
        for p in passages {
            guard let key = p.citeKey, !key.isEmpty else { continue }
            title[key] = p.title
            if pages[key] == nil { pages[key] = [] }
            if let page = p.page { pages[key]?.insert(page) }
        }
        guard !title.isEmpty else { return "" }

        // Prefer the keys the model actually cited; otherwise list what it consulted.
        let cited = Self.citedKeys(in: answer).filter { title[$0] != nil }
        let keys = (cited.isEmpty ? Array(title.keys) : Array(cited))
            .sorted { (title[$0] ?? "") < (title[$1] ?? "") }
        let heading = cited.isEmpty ? "### Sources consulted" : "### Sources"

        var out = "\n\n\(heading)\n"
        for key in keys {
            let pageList = (pages[key] ?? []).sorted()
            let pageStr = pageList.isEmpty ? "" : " — " + pageList.map { "p.\($0)" }.joined(separator: ", ")
            out += "- [\(key)] \(title[key] ?? "Unknown")\(pageStr)\n"
        }
        return out
    }

    /// Extract citeKeys from `oak://cite/{citeKey}?...` links in the answer.
    private static func citedKeys(in answer: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "oak://cite/([A-Za-z0-9_.:\\-]+)") else {
            return []
        }
        let range = NSRange(answer.startIndex..., in: answer)
        var keys: Set<String> = []
        for match in regex.matches(in: answer, range: range) {
            if let r = Range(match.range(at: 1), in: answer) {
                keys.insert(String(answer[r]))
            }
        }
        return keys
    }
}
