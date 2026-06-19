import Foundation
import AppKit
import PDFKit
import OakAgent

struct CitationAnchor {
    var page: Int?      // 0-based page index (already converted from 1-based)
    var heading: String?
    var time: Double?   // seconds
    var text: String?   // text fragment to find & highlight

    /// Parse an `oak://cite/{citeKey}?page=N&heading=...&time=S&text=...` URL
    /// into a `(citeKey, anchor)` pair. Returns nil for non-citation URLs.
    static func parse(from url: URL) -> (citeKey: String, anchor: CitationAnchor)? {
        guard url.scheme == "oak" else { return nil }

        // oak://page/N → current-document page citation (empty citeKey)
        if url.host == "page",
           let pageStr = url.pathComponents.dropFirst().first,
           let page = Int(pageStr) {
            return ("", CitationAnchor(page: page - 1))
        }

        // oak://cite/{citeKey}?page=N&heading=...&time=S&text=...
        guard url.host == "cite",
              let citeKey = url.pathComponents.dropFirst().first else {
            return nil
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []

        var anchor = CitationAnchor()
        for item in queryItems {
            switch item.name {
            case "page":
                if let v = item.value, let p = Int(v) { anchor.page = p - 1 }
            case "heading":
                anchor.heading = formDecode(item.value)
            case "time":
                if let v = item.value, let t = Double(v) { anchor.time = t }
            case "text":
                anchor.text = formDecode(item.value)
            default:
                break
            }
        }

        return (citeKey, anchor)
    }

    /// Form-urlencoded decode for query values. `URLComponents.queryItems` already
    /// percent-decodes `%XX`, but it does NOT turn `+` into a space — and the model
    /// is told to encode spaces as `+` (see LLMContextProvider citation examples).
    /// Without this, `text=a+b+c` would be searched literally (plus signs and all)
    /// and never match the PDF, so the citation jumps to the page but never highlights.
    private static func formDecode(_ value: String?) -> String? {
        guard let value else { return nil }
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

struct PendingConfirmation {
    let toolCall: ToolCall
    let category: ToolCategory
    let continuation: CheckedContinuation<Bool, Never>
}

@Observable
class ChatViewModel {
    weak var parent: DocumentViewModel?
    weak var appState: AppState?

    // MARK: - State

    var turns: [Turn] = []
    var inputText: String = ""
    var isStreaming: Bool = false
    var selectedSkill: Skill? = nil
    var activeTokens: [ChatCompletionItem] = []
    var pendingAttachments: [TurnAttachment] = []
    var inputResetToken: Int = 0
    var showSettings: Bool = false
    var errorMessage: String?
    var pendingToolConfirmation: PendingConfirmation?
    /// Live status from the research subagent while it runs (nil when idle).
    var researchActivity: String?

    /// Transient "memory updated / saved" notice shown in the chat (nil when idle).
    /// Set by the `manage_memory` tool when it writes; auto-clears.
    var memoryNotice: String?
    private var memoryNoticeToken: Int = 0

    /// Set by external actions (e.g. context menu "Add to Chat") and consumed by AIChatView.
    var pendingLibraryRef: LibraryItem?

    // Session
    var sessionId: UUID = UUID()
    var sessions: [ConversationMeta] = []

    // History
    var sessionService: ConversationService?
    var sessionList: [ConversationMeta] = []
    var showHistory: Bool = false
    /// The item ID to associate sessions with (set externally for document-scoped chat).
    var itemId: String?

    /// Working directory for the library agent workspace — a CoW-mounted folder
    /// under `<dataDir>/workspace/`. When set, the agent's file tools are rooted
    /// here (set externally by `AppState` when the agent workspace is active).
    var workspaceDirectory: URL?

    // MARK: - Private

    private let engine: AgentSession
    private let contextProvider = LLMContextProvider()
    private var streamTask: Task<Void, Never>?
    /// Whether a DB record has been created for the current session.
    private var sessionRecordCreated: Bool = false
    /// Whether an auto title has been generated for the current session (once per chat).
    private var titleGenerated: Bool = false
    /// Tool context for AI agent tool use (path sandbox).
    private var toolContext: ToolExecutionContext?

    /// Observer for cite-key rewrites, so an open chat reloads stale `oak://cite/` links.
    private var citeKeyRewriteObserver: NSObjectProtocol?

    init(parent: DocumentViewModel, documentStoragePath: URL? = nil) {
        self.parent = parent
        self.engine = AgentSession(chatsDirectory: CatalogDatabase.chatsDirectory)
        if let path = documentStoragePath {
            // Sandbox tool access to the document storage directory
            self.toolContext = ToolExecutionContext(
                workingDirectory: path,
                allowedPaths: [path]
            )
        }
        observeCiteKeyRewrites()
    }

    init() {
        self.parent = nil
        self.engine = AgentSession(chatsDirectory: CatalogDatabase.chatsDirectory)
        observeCiteKeyRewrites()
    }

    deinit {
        if let citeKeyRewriteObserver {
            NotificationCenter.default.removeObserver(citeKeyRewriteObserver)
        }
    }

    /// When a cite key is regenerated, its `oak://cite/` links are rewritten on disk. If this
    /// chat is showing an affected session and isn't mid-stream, reload it so the displayed
    /// links match disk (the persisted data is already correct either way).
    private func observeCiteKeyRewrites() {
        citeKeyRewriteObserver = NotificationCenter.default.addObserver(
            forName: .oakCiteKeysRewritten, object: nil, queue: .main
        ) { [weak self] note in
            let sessions = note.userInfo?["sessions"] as? [UUID] ?? []
            Task { @MainActor in
                guard let self, !self.isStreaming, sessions.contains(self.sessionId) else { return }
                self.loadSession(self.sessionId)
            }
        }
    }

    // MARK: - Configuration

    var config: ProviderConfig {
        let prefs = Preferences.shared
        let storedPid = prefs.aiProviderId
        let pid = ConfiguredProviderStore.shared.resolvedProviderId(preferred: storedPid)
        let provider = ProviderRegistry.shared.provider(for: pid)
        let defaultModel = provider?.defaultModelId ?? ""
        // Keep the stored model only when it belongs to the provider we resolved to;
        // otherwise (e.g. we fell back from an unconfigured default) use the provider's
        // own default rather than a model from a different vendor.
        let storedModelValid = pid == storedPid
            && !prefs.aiModel.isEmpty
            && provider?.models.contains { $0.id == prefs.aiModel } == true
        let modelId = storedModelValid ? prefs.aiModel : defaultModel
        let modelInfo = provider?.models.first { $0.id == modelId }
        let isReasoning = modelInfo?.reasoning == true
        let effort = prefs.thinkingEffort
        let thinkingEnabled = isReasoning && effort != "off"
        return ProviderConfig(
            providerId: pid,
            model: modelId,
            thinkingBudget: thinkingEnabled ? prefs.thinkingBudget : nil,
            thinkingEffort: thinkingEnabled ? effort : nil
        )
    }

    /// Config for the research subagent's loop: same provider, but a cheaper/faster
    /// model when `researchModel` is set, and no extended thinking (it's tool-driven).
    var researchConfig: ProviderConfig {
        let prefs = Preferences.shared
        let researchModel = prefs.researchModel
        let base = config
        return ProviderConfig(
            providerId: base.providerId,
            model: researchModel.isEmpty ? base.model : researchModel,
            thinkingBudget: nil,
            thinkingEffort: nil
        )
    }

    // MARK: - Completion Items

    /// Items shown in the `/` slash completion panel.
    @MainActor
    var chatSlashItems: [ChatCompletionItem] {
        ChatCompletionItem.slashItems(
            installed: SkillManager.shared.installedSkills
        )
    }

    /// Items shown in the `@`-mention panel: documents in the CURRENT collection that
    /// the user can attach as context (the keyboard path to what drag-and-drop already
    /// does). Scoped to the selected collection — not the whole library — so `@` mirrors
    /// what the user is actually working in (the same set grounded chat retrieves over).
    /// Cached in a stored property because the DB fetch is too costly to run on
    /// every SwiftUI update — `refreshAtMentionItems()` repopulates it on appear
    /// and when a new session starts.
    var atMentionItems: [ChatCompletionItem] = []

    @MainActor
    func refreshAtMentionItems() {
        guard let store = parent?.libraryStore ?? appState?.libraryStore else {
            atMentionItems = []
            return
        }
        // `filteredItems` already respects the selected collection / smart filter, so this
        // surfaces only the current collection's documents instead of the entire library.
        let recent = store.filteredItems.sorted { $0.dateAdded > $1.dateAdded }.prefix(60)
        atMentionItems = recent.map { ChatCompletionItem.libraryReference(from: $0, trigger: "@") }
    }

    // MARK: - Send Message

    @MainActor
    func send() {
        let parsedInput = Self.extractLeadingSkillTags(from: inputText.trimmingCharacters(in: .whitespacesAndNewlines))
        let text = parsedInput.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !parsedInput.skillIds.isEmpty || !activeTokens.isEmpty else { return }
        Analytics.capture("ai_chat_sent")

        let attachments = pendingAttachments
        let tokens = activeTokens
        inputText = ""
        activeTokens = []
        pendingAttachments = []
        inputResetToken += 1
        isStreaming = true
        errorMessage = nil

        // Extract skill from tokens (overrides typed tags and selectedSkill)
        let tokenSkill: Skill? = tokens.lazy.compactMap { item -> Skill? in
            if case .installedSkill(let skill) = item.kind { return skill }
            return nil
        }.first

        // Also support an explicit leading markdown tag: [[skill:skill-id]].
        let taggedSkill: Skill? = parsedInput.skillIds.lazy.compactMap { skillId in
            SkillManager.shared.installedSkills.first {
                $0.id.caseInsensitiveCompare(skillId) == .orderedSame
                    || $0.name.caseInsensitiveCompare(skillId) == .orderedSame
            }
        }.first

        let effectiveSkill = tokenSkill ?? taggedSkill ?? selectedSkill
        let sendText = text.isEmpty ? (effectiveSkill?.name ?? "Go") : text
        var userContent = effectiveSkill.map { Self.contentWithSkillTag(skillId: $0.id, text: text) } ?? sendText

        // Extract library reference tokens and append XML block
        let libraryRefs = tokens.compactMap { token -> ChatCompletionItem.LibraryRefPayload? in
            if case .libraryReference(let p) = token.kind { return p }
            return nil
        }
        if !libraryRefs.isEmpty {
            userContent += "\n\n" + Self.buildReferencedDocumentsXML(libraryRefs: libraryRefs)
        }

        // Create or update session record in DB
        persistSessionMetadata(firstUserMessage: sendText)

        // Defer the heavy context-snapshot + tool build off the synchronous send()
        // path. `isStreaming = true` (and the cleared input) only paint once send()
        // returns to the runloop, so doing the snapshot here would freeze the UI for
        // its whole duration — and on a wide-context model the snapshot can extract a
        // large amount of document text. Yielding first lets the "sent" state paint,
        // then we build context and start streaming on the next tick.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.startStream(
                effectiveSkill: effectiveSkill,
                userContent: userContent,
                attachments: attachments
            )
        }
    }

    /// Builds the context snapshot + tool set and kicks off the streaming task.
    /// Split out of `send()` so the synchronous input handling can return to the
    /// runloop (painting the cleared input + streaming indicator) before this work.
    @MainActor
    private func startStream(
        effectiveSkill: Skill?,
        userContent: String,
        attachments: [TurnAttachment]
    ) {
        // Build enriched context snapshot. The document-text budget scales with the
        // active model's context window (replaces the old fixed 4 000-char cap), so a
        // whole short document loads in full on a large window.
        let contextMode = effectiveSkill?.contextMode ?? .currentPage
        let docCharBudget = LLMContextProvider.documentCharBudget(
            contextWindow: config.modelInfo?.contextWindow ?? 200_000
        )
        let snapshot = LLMContextProvider.buildContextSnapshot(
            from: parent,
            appState: parent?.appState ?? appState,
            contextMode: contextMode,
            documentCharBudget: docCharBudget
        )

        // The system prompt is assembled inside the stream task below, where we can
        // await the open document's current-page chunks (injected as citable `?c=`
        // passages). `currentSkill` is also reused for `turnMetadata`.
        let currentSkill = effectiveSkill

        let currentHistory = turns.filter { !$0.isStreaming }
        let currentSessionId = sessionId
        let currentConfig = config
        let turnMetadata: [String: String] = currentSkill.map { ["skill": $0.id] } ?? [:]

        let prefs = Preferences.shared

        // Build tools list
        var tools: [any AgentTool] = []

        // 1. Document tools (always when a document is open)
        if let doc = snapshot.document {
            tools.append(ReadDocumentTool(
                filePath: doc.filePath,
                documentType: doc.contentType,
                pageCount: doc.pageCount
            ))
            tools.append(SearchDocumentTool(
                filePath: doc.filePath,
                documentType: doc.contentType,
                pageCount: doc.pageCount
            ))

            // Browser tool — only when viewing a live web page (.link). Lets the agent
            // pull the live, rendered, logged-in DOM as readable markdown on demand.
            if doc.contentType == .link {
                tools.append(ReadCurrentPageTool())
            }
        }

        // 2. Full-text content search (FTS5 over the indexed library), plus a
        //    research subagent for deep multi-document questions (its own loop).
        if let ftsService = appState?.ftsIndexService {
            // GROUNDED scope: when a real collection is selected, physically restrict
            // retrieval to its members so the agent literally cannot answer from
            // outside the user's sources. `scopeId` is nil for smart / "All Items".
            let scopeId = snapshot.activeCollection?.scopeId

            var fts = FTSSearchTool(service: ftsService)
            fts.scopeCollectionId = scopeId
            tools.append(fts)

            let activitySink: @Sendable (String) -> Void = { [weak self] status in
                Task { @MainActor in self?.researchActivity = status }
            }
            var research = ResearchTool(
                searchService: ftsService,
                config: researchConfig,
                onActivity: activitySink
            )
            research.scopeCollectionId = scopeId
            tools.append(research)
        }

        // 3. Web search (always)
        tools.append(AcademicSearchTool())
        tools.append(WebSearchTool())
        tools.append(WebFetchTool())

        // 3b. Oak CLI (library search, read items, list collections/tags, manage library)
        tools.append(OakCLITool())

        // 3c. Memory — ChatGPT `bio`-style: the model saves durable facts about the
        //     user inline (proactively when they share something lasting, and on
        //     explicit request), into one global profile. Gated by the memory toggle.
        if Preferences.shared.memoryEnabled {
            tools.append(MemoryTool())
        }

        // 4. Filesystem tools (user preference gated). Available for a document's
        //    storage dir or the library agent's CoW workspace folder.
        if prefs.agentToolsEnabled, toolContext != nil || workspaceDirectory != nil {
            if prefs.agentReadFileEnabled { tools.append(ReadTool()) }
            if prefs.agentWriteFileEnabled { tools.append(WriteTool()) }
            tools.append(BashTool())
        }

        let currentTools: [any AgentTool]? = tools.isEmpty ? nil : tools

        // Ensure a tool context exists when document tools are present
        let effectiveToolContext: ToolExecutionContext?
        if !tools.isEmpty {
            let storagePath = parent?.itemStorageKey.map {
                CatalogDatabase.documentDirectory(storageKey: $0)
            }
            // Allow tools to access everything under ~/OakReader-Dev/ (debug) or ~/OakReader/ (prod)
            let allowed = [CatalogDatabase.dataDirectory]
            // Prefer the agent workspace folder, then the document's storage dir.
            let workingDir = workspaceDirectory ?? storagePath ?? URL(fileURLWithPath: NSTemporaryDirectory())
            effectiveToolContext = toolContext ?? ToolExecutionContext(
                workingDirectory: workingDir,
                allowedPaths: allowed
            )
        } else {
            effectiveToolContext = nil
        }

        let permissionLevel = prefs.agentPermissionLevel

        // Load file-based agent skills from standard directories
        let agentSkills = Self.loadAgentSkills()
        let thinkingBudget = currentConfig.thinkingBudget
        let thinkingEffort = currentConfig.thinkingEffort

        streamTask = Task { @MainActor [weak self] in
            do {
                // Inject the open document's current page as citable `?c=` passages
                // (PDF, when indexed) so the model cites the page it's reading the
                // same validated way it cites retrieved passages. Built here, not in
                // the synchronous prelude, because the chunk fetch is async.
                let pageChunks = await self?.currentPageChunks(snapshot: snapshot) ?? []
                let systemPrompt = LLMContextProvider.buildSystemPrompt(
                    skill: currentSkill,
                    context: snapshot,
                    documentCharBudget: docCharBudget,
                    currentPageChunks: pageChunks
                )

                let stream = await engine.send(
                    userContent: userContent,
                    attachments: attachments,
                    history: currentHistory,
                    sessionId: currentSessionId,
                    config: currentConfig,
                    systemPrompt: systemPrompt,
                    turnMetadata: turnMetadata,
                    tools: currentTools,
                    toolContext: effectiveToolContext,
                    agentSkills: agentSkills,
                    thinkingBudget: thinkingBudget,
                    thinkingEffort: thinkingEffort,
                    toolConfirmation: self?.makeToolConfirmation(level: permissionLevel)
                )

                var assistantTurnId: UUID?

                // Coalesce streaming text deltas so the observed `turns` array
                // mutates a few times per second instead of once per token.
                // Per-token mutation forces SwiftUI to re-render the streaming
                // bubble on every token — the main source of chat jank at high
                // token rates. The glyph fade-in in the text view animates each
                // committed chunk smoothly, and `.finished` always overwrites with
                // the engine's authoritative full content, so buffering changes only
                // render cadence, never correctness.
                var pendingText = ""
                var lastCommitNanos = DispatchTime.now().uptimeNanoseconds
                let commitIntervalNanos: UInt64 = 33_000_000  // ~30 commits/sec
                func commitPendingText() {
                    guard !pendingText.isEmpty else { return }
                    if let id = assistantTurnId,
                       let idx = turns.lastIndex(where: { $0.id == id })
                    {
                        turns[idx].content += pendingText
                    }
                    pendingText = ""
                    lastCommitNanos = DispatchTime.now().uptimeNanoseconds
                }

                for try await event in stream {
                    // The user switched/cleared/loaded a different session mid-stream.
                    // Stop before writing the old response into the new chat (and
                    // before flipping its `isStreaming`/indicator state).
                    if sessionId != currentSessionId { break }
                    switch event {
                    case .delta(let delta):
                        if assistantTurnId != nil {
                            pendingText += delta
                            let now = DispatchTime.now().uptimeNanoseconds
                            if pendingText.utf8.count >= 256 || now &- lastCommitNanos >= commitIntervalNanos {
                                commitPendingText()
                            }
                        } else {
                            // First delta — create assistant turn placeholder and
                            // show it immediately so the response feels responsive.
                            let newTurn = Turn(
                                role: .assistant,
                                content: delta,
                                isStreaming: true
                            )
                            assistantTurnId = newTurn.id
                            turns.append(newTurn)
                            lastCommitNanos = DispatchTime.now().uptimeNanoseconds
                        }

                    case .thinkingDelta(let text):
                        if let id = assistantTurnId,
                           let idx = turns.lastIndex(where: { $0.id == id })
                        {
                            if turns[idx].thinking == nil {
                                turns[idx].thinking = text
                            } else {
                                turns[idx].thinking! += text
                            }
                        } else {
                            // First thinking delta — create assistant turn placeholder
                            let newTurn = Turn(
                                role: .assistant,
                                content: "",
                                isStreaming: true,
                                thinking: text
                            )
                            assistantTurnId = newTurn.id
                            turns.append(newTurn)
                        }

                    case .toolInputDelta:
                        // No tool renders in-progress input anymore; the completed
                        // tool-use record is surfaced via the generic summary.
                        break

                    case .toolUseStarted(let record):
                        // A tool-only iteration emits no text/thinking delta before
                        // running tools, so `assistantTurnId` may still be nil here.
                        // Create the turn now so the executing record renders (and the
                        // tool-call shimmer animates) while the tool runs.
                        let idx: Int
                        if let id = assistantTurnId,
                           let existing = turns.lastIndex(where: { $0.id == id })
                        {
                            idx = existing
                        } else {
                            let newTurn = Turn(role: .assistant, content: "", isStreaming: true)
                            assistantTurnId = newTurn.id
                            turns.append(newTurn)
                            idx = turns.count - 1
                        }
                        // Upsert: a provisional record may already exist from
                        // streaming tool-input deltas.
                        if let toolIdx = turns[idx].toolUses.firstIndex(where: { $0.id == record.id }) {
                            turns[idx].toolUses[toolIdx] = record
                        } else {
                            turns[idx].toolUses.append(record)
                        }

                    case .toolUsePending(let record):
                        let idx: Int
                        if let id = assistantTurnId,
                           let existing = turns.lastIndex(where: { $0.id == id })
                        {
                            idx = existing
                        } else {
                            let newTurn = Turn(role: .assistant, content: "", isStreaming: true)
                            assistantTurnId = newTurn.id
                            turns.append(newTurn)
                            idx = turns.count - 1
                        }
                        if let toolIdx = turns[idx].toolUses.firstIndex(where: { $0.id == record.id }) {
                            turns[idx].toolUses[toolIdx] = record
                        } else {
                            turns[idx].toolUses.append(record)
                        }

                    case .toolUseCompleted(let record):
                        if let id = assistantTurnId,
                           let idx = turns.lastIndex(where: { $0.id == id }),
                           let toolIdx = turns[idx].toolUses.firstIndex(where: { $0.id == record.id })
                        {
                            turns[idx].toolUses[toolIdx] = record
                        }
                        // Surface explicit memory writes (not plain `list` reads).
                        if record.name == "manage_memory", !record.isError {
                            let op = (record.input["operation"] ?? "").lowercased()
                            if op != "list" { self?.flashMemoryNotice("Memory updated") }
                        }

                    case .finished(let turn):
                        // The resolved content below is authoritative and replaces
                        // whatever was streamed, so drop any uncommitted tail.
                        pendingText = ""
                        // Resolve any chunk-id citations (`?c=<id>`) the model emitted
                        // into durable, validated `?page=&text=` anchors before the
                        // message settles into history. No-op when there are none.
                        let resolvedContent = turn.role == .assistant
                            ? await self?.resolveChunkCitations(turn.content) ?? turn.content
                            : turn.content
                        if turn.role == .user {
                            turns.append(turn)
                        } else if let id = assistantTurnId,
                                  let idx = turns.lastIndex(where: { $0.id == id })
                        {
                            turns[idx].content = resolvedContent
                            turns[idx].isStreaming = false
                            turns[idx].toolUses = turn.toolUses
                            if let thinking = turn.thinking {
                                turns[idx].thinking = thinking
                            }

                            // If this turn had tool uses, reset assistantTurnId
                            // so the next loop iteration creates a new bubble
                            if !turn.toolUses.isEmpty {
                                assistantTurnId = nil
                            }
                        } else {
                            var finalTurn = turn
                            finalTurn.content = resolvedContent
                            finalTurn.isStreaming = false
                            turns.append(finalTurn)

                            if !turn.toolUses.isEmpty {
                                assistantTurnId = nil
                            }
                        }

                    case .error(let error):
                        // No `.finished` will arrive to reconcile — flush the tail
                        // so the partial answer stays visible alongside the error.
                        commitPendingText()
                        errorMessage = error.localizedDescription
                        if let id = assistantTurnId,
                           let idx = turns.lastIndex(where: { $0.id == id })
                        {
                            turns[idx].isStreaming = false
                            turns[idx].error = error.localizedDescription
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) && sessionId == currentSessionId {
                    errorMessage = error.localizedDescription
                }
            }

            // Only clear streaming state if we're still on the same session — a
            // switch already reset it for the new chat, and clobbering it here
            // would stop the new chat's indicator.
            if sessionId == currentSessionId {
                isStreaming = false
                researchActivity = nil
            }
            self?.titleIfNeeded()
        }
    }

    // MARK: - Auto Chat Title

    /// After the first exchange settles, generate a short title in the background.
    /// Runs once per chat, off the hot path, fail-soft — keeps the truncated
    /// first-message placeholder on any failure.
    private func titleIfNeeded() {
        guard !titleGenerated, sessionRecordCreated else { return }
        let settled = turns.filter { !$0.isStreaming && $0.role != .system }
        guard let firstUser = settled.first(where: { $0.role == .user })?.content,
              let firstAssistant = settled.first(where: { $0.role == .assistant })?.content,
              !firstUser.isEmpty, !firstAssistant.isEmpty
        else { return }

        titleGenerated = true
        let sid = sessionId
        let cfg = researchConfig  // cheaper/faster model when `researchModel` is set; no thinking
        let count = settled.count

        Task { @MainActor [weak self] in
            guard let self,
                  let title = await ChatTitleService.generate(
                      firstUser: firstUser, firstAssistant: firstAssistant, config: cfg
                  )
            else { return }
            // Persist and reflect into the in-memory list so the sidebar updates live.
            try? self.sessionService?.updateSession(id: sid, title: title, messageCount: count)
            if let idx = self.sessionList.firstIndex(where: { $0.id == sid }) {
                self.sessionList[idx].title = title
            }
        }
    }

    /// Briefly surface a memory-write in the chat UI (auto-clears). Tappable in
    /// AIChatView to open the memory manager.
    func flashMemoryNotice(_ text: String) {
        memoryNoticeToken &+= 1
        let token = memoryNoticeToken
        memoryNotice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.memoryNoticeToken == token else { return }
            self.memoryNotice = nil
        }
    }

    // MARK: - Tool Confirmation

    func approveToolCall() {
        guard let pending = pendingToolConfirmation else { return }
        pendingToolConfirmation = nil
        pending.continuation.resume(returning: true)
    }

    func denyToolCall() {
        guard let pending = pendingToolConfirmation else { return }
        pendingToolConfirmation = nil
        pending.continuation.resume(returning: false)
    }

    /// Build a tool confirmation callback based on the permission level.
    /// - `full`: returns nil (no confirmation needed — full permission)
    /// - `smart`: auto-approves `.readOnly`, asks for `.write`/`.dangerous`
    /// - `restricted`: asks for everything
    private func makeToolConfirmation(level: AgentPermissionLevel) -> (@Sendable (ToolCall, ToolCategory) async -> Bool)? {
        switch level {
        case .full:
            return nil
        case .smart:
            return { [weak self] call, category in
                // Read-only tools auto-approved in smart mode
                if category == .readOnly { return true }
                return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let pending = PendingConfirmation(toolCall: call, category: category, continuation: continuation)
                    DispatchQueue.main.async {
                        self?.pendingToolConfirmation = pending
                    }
                }
            }
        case .restricted:
            return { [weak self] call, category in
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let pending = PendingConfirmation(toolCall: call, category: category, continuation: continuation)
                    DispatchQueue.main.async {
                        self?.pendingToolConfirmation = pending
                    }
                }
            }
        }
    }

    // MARK: - Citation Navigation

    func openCitation(citeKey: String, anchor: CitationAnchor) {
        // Backward compat: empty citeKey means current document (oak://page/N)
        if citeKey.isEmpty {
            if let vm = parent {
                navigateInPlace(vm: vm, anchor: anchor)
            }
            return
        }

        // Check if the citeKey matches the current document
        let currentCiteKey = parent?.libraryItem?.citeKey
        if let currentCiteKey, currentCiteKey == citeKey, let vm = parent {
            navigateInPlace(vm: vm, anchor: anchor)
            return
        }

        // Cross-document: find item in library, open it, then navigate
        guard let appState else { return }
        let store = appState.libraryStore
        guard let item = store.findItem(byCiteKey: citeKey) else { return }

        // Media (podcast / video) has no local seekable copy — open the source
        // platform at the timestamp instead of opening a document tab.
        if let time = anchor.time, openSourceTimestamp(for: item, seconds: time) { return }

        appState.openLibraryItem(item)

        // Delay navigation until the new tab loads
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let tab = appState.activeTab else { return }
            self.navigateInPlace(vm: tab.viewModel, anchor: anchor)
        }
    }

    /// Resolve `?c=<chunkId>` citations in a settled assistant message into durable
    /// `?page=&text=` anchors, validated against the FTS chunk store. No-op without a
    /// chunk id in the text or an available index service.
    private func resolveChunkCitations(_ content: String) async -> String {
        guard let fts = (appState ?? parent?.appState)?.ftsIndexService else { return content }
        return await ChunkCitationResolver.resolve(in: content, using: fts)
    }

    /// The open document's citable `?c=` passages, when indexed. For PDFs this is the
    /// current page's chunks; for non-paginated docs (HTML / markdown / saved web clips)
    /// it's the whole body's chunks. Empty otherwise — the prompt then falls back to raw
    /// page text. Giving HTML the same chunk-id path as PDF is what lets web citations
    /// resolve to a verbatim, reliably-anchorable quote instead of a model paraphrase.
    private func currentPageChunks(snapshot: ChatContextSnapshot) async -> [LLMContextProvider.CurrentPageChunk] {
        guard let doc = snapshot.document,
              let itemId,
              let fts = (appState ?? parent?.appState)?.ftsIndexService
        else { return [] }
        let chunks: [FTSChunk]
        switch doc.contentType {
        case .pdf:
            chunks = await fts.currentPageChunks(itemId: itemId, page: doc.currentPageIndex)
        case .html, .markdown, .link:
            chunks = await fts.allChunks(itemId: itemId)
        default:
            return []
        }
        return chunks.compactMap { c in
            c.id.map { LLMContextProvider.CurrentPageChunk(id: $0, page: c.pageStart, text: c.chunkText) }
        }
    }

    private func navigateInPlace(vm: DocumentViewModel, anchor: CitationAnchor) {
        // A live web page is `.link` with no timeline; it navigates like HTML
        // (find-text / scroll-to-heading) rather than opening a `?time=` source.
        let isTimelineMedia = vm.contentType == .audio
            || (vm.mediaDocument.map {
                $0.metadata.resolvedEmbedType == .youtube || $0.metadata.duration != nil
            } ?? false)

        switch vm.contentType {
        case .pdf:
            if let page = anchor.page {
                vm.viewer.goToPage(page)
            }
            if let text = anchor.text {
                // Tolerant search: the model's text= is often a paraphrase, so exact
                // findString would miss it. Prefer the cited page when the phrase recurs.
                Task { @MainActor in
                    await vm.viewer.highlightCitation(text: text, page: anchor.page)
                }
            }

        case .html, .markdown:
            navigateWebView(anchor: anchor)

        case .link where !isTimelineMedia:
            // Live web page — same WKWebView highlight path as saved HTML clips.
            navigateWebView(anchor: anchor)

        case .link, .audio:
            // Timeline media — open the source platform at the timestamp.
            if let time = anchor.time, let source = vm.mediaDocument?.sourceURL {
                NSWorkspace.shared.open(MediaTimestampLink.url(forSource: source, atSeconds: time))
            }
        }
    }

    /// Drives the WKWebView citation highlight (mark.js find / scroll-to-heading)
    /// used by saved HTML clips and live web pages alike.
    private func navigateWebView(anchor: CitationAnchor) {
        if let heading = anchor.heading {
            NotificationCenter.default.post(name: .webViewScrollToHeading, object: heading)
        } else if let text = anchor.text {
            NotificationCenter.default.post(name: .webViewFindText, object: text)
        }
    }

    /// Opens a media item's source platform at `seconds` (YouTube / Apple Podcasts /
    /// generic). Returns false if the item isn't media or has no resolvable source URL,
    /// so the caller can fall back to opening it as a document.
    private func openSourceTimestamp(for item: LibraryItem, seconds: Double) -> Bool {
        guard item.contentType == .link || item.contentType == .audio else { return false }
        let source: URL?
        if let s = item.sourceURL {
            source = s
        } else if let dir = item.primaryAttachment?.documentDirectory,
                  let media = try? MediaDocument(storageDirectory: dir) {
            source = media.sourceURL
        } else {
            source = nil
        }
        guard let source else { return false }
        NSWorkspace.shared.open(MediaTimestampLink.url(forSource: source, atSeconds: seconds))
        return true
    }

    // MARK: - Stop Streaming

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        researchActivity = nil

        // Finalize any streaming turn
        if let idx = turns.lastIndex(where: { $0.isStreaming }) {
            turns[idx].isStreaming = false
        }
    }

    // MARK: - Attachments

    func addTextAttachment(_ text: String, pageIndex: Int) {
        let attachment = TurnAttachment(
            type: .textSelection,
            label: "Page \(pageIndex + 1), selected text",
            textContent: text,
            pageIndex: pageIndex
        )
        pendingAttachments.append(attachment)
    }

    func addImageAttachment(_ imageData: Data, pageIndex: Int) {
        let attachment = TurnAttachment(
            type: .imageCapture,
            label: "Page \(pageIndex + 1), region capture",
            imageData: imageData,
            pageIndex: pageIndex
        )
        pendingAttachments.append(attachment)
    }

    func addClipboardImage(_ imageData: Data) {
        let attachment = TurnAttachment(
            type: .imageCapture,
            label: "Pasted image",
            imageData: imageData
        )
        pendingAttachments.append(attachment)
    }

    func addUploadedFile(_ imageData: Data, filename: String) {
        let attachment = TurnAttachment(
            type: .imageCapture,
            label: filename,
            imageData: imageData
        )
        pendingAttachments.append(attachment)
    }

    func addDocumentPageSnapshot() {
        guard let vm = parent else { return }
        let pageIndex = vm.state.currentPageIndex
        guard let pdfDoc = vm.pdfDocument, let page = pdfDoc.page(at: pageIndex) else { return }
        let renderer = PDFRenderingService()
        guard let cgImage = renderer.renderPage(page, dpi: 150) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = TurnAttachment(
            type: .imageCapture,
            label: "Page \(pageIndex + 1), \(vm.fileName)",
            imageData: pngData,
            pageIndex: pageIndex
        )
        pendingAttachments.append(attachment)
    }

    func removePendingAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: - Session Management

    /// Cancel any in-flight stream before switching sessions, so the old response
    /// can't keep streaming into — or finalize into — the new chat. The loop's
    /// `sessionId` guard is the backstop; this stops the work promptly.
    private func cancelActiveStreamForSwitch() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        researchActivity = nil
    }

    func newSession() {
        cancelActiveStreamForSwitch()
        turns = []
        sessionId = UUID()
        sessionRecordCreated = false
        titleGenerated = false
        selectedSkill = nil
        activeTokens = []
        pendingAttachments = []
        inputText = ""
        errorMessage = nil
        showHistory = false
    }

    func loadSession(_ id: UUID) {
        cancelActiveStreamForSwitch()
        sessionId = id
        sessionRecordCreated = true  // already exists in DB
        titleGenerated = true  // existing session already has a title; don't overwrite
        turns = []
        showHistory = false
        Task { @MainActor in
            do {
                turns = Self.normalizedSkillMetadata(try await engine.loadSession(id))
            } catch {
                errorMessage = "Failed to load session: \(error.localizedDescription)"
            }
        }
    }

    func clearSession() {
        cancelActiveStreamForSwitch()
        let oldSessionId = sessionId
        Task {
            await engine.deleteSession(oldSessionId)
        }
        if sessionRecordCreated {
            try? sessionService?.deleteSession(id: oldSessionId)
        }
        turns = []
        errorMessage = nil
        sessionId = UUID()
        sessionRecordCreated = false
        titleGenerated = false
    }

    // MARK: - Session History

    func loadSessionList() {
        guard let service = sessionService else { return }
        do {
            if let docId = itemId {
                sessionList = try service.fetchSessions(forItemId: docId)
            } else {
                sessionList = try service.fetchLibrarySessions()
            }
        } catch {
            sessionList = []
        }
    }

    func deleteSessionFromList(_ id: UUID) {
        // Delete from DB
        try? sessionService?.deleteSession(id: id)
        // Delete JSONL file
        Task {
            await engine.deleteSession(id)
        }
        // Remove from local list
        sessionList.removeAll { $0.id == id }
        // If the deleted session is the current one, start fresh
        if sessionId == id {
            newSession()
        }
    }

    // MARK: - Skill Tags / Metadata Normalization

    /// Special inline tags stored in user messages for durable UI rendering.
    /// Example: `[[skill:summarize]] Please summarize this page.`
    private static func extractLeadingSkillTags(from content: String) -> (skillIds: [String], content: String) {
        var remaining = content
        var skillIds: [String] = []

        while true {
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[[skill:") else { break }
            guard let closeRange = trimmed.range(of: "]]") else { break }

            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: "[[skill:".count)
            let rawSkill = String(trimmed[valueStart..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawSkill.isEmpty {
                skillIds.append(rawSkill)
            }
            remaining = String(trimmed[closeRange.upperBound...])
        }

        return (skillIds, remaining.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func contentWithSkillTag(skillId: String, text: String) -> String {
        if text.isEmpty { return "[[skill:\(skillId)]]" }
        return "[[skill:\(skillId)]]\n\(text)"
    }

    /// Older chat records stored skill metadata on the assistant turn. For display,
    /// a skill belongs to the user's request, so move it to the preceding user turn.
    private static func normalizedSkillMetadata(_ turns: [Turn]) -> [Turn] {
        var normalized = turns
        for idx in normalized.indices where normalized[idx].role == .assistant {
            guard let skill = normalized[idx].metadata["skill"] else { continue }
            if let userIdx = normalized[..<idx].lastIndex(where: { $0.role == .user }) {
                if normalized[userIdx].metadata["skill"] == nil {
                    normalized[userIdx].metadata["skill"] = skill
                }
                if extractLeadingSkillTags(from: normalized[userIdx].content).skillIds.isEmpty {
                    normalized[userIdx].content = contentWithSkillTag(skillId: skill, text: normalized[userIdx].content)
                }
            }
            normalized[idx].metadata.removeValue(forKey: "skill")
        }
        return normalized
    }

    // MARK: - Referenced Documents XML

    private static func buildReferencedDocumentsXML(
        libraryRefs: [ChatCompletionItem.LibraryRefPayload]
    ) -> String {
        // The user attached these library documents as context, but their full text
        // is NOT inlined here (it can be large). Tell the model exactly how to pull a
        // doc's content on demand: read it with the oak tool by its title or cite-key.
        // Without this instruction the model only sees the metadata and (rightly)
        // responds that it lacks the document body.
        //
        // NOTE: the opening tag MUST stay bare `<referenced-documents>` — the chat
        // bubble (ChatBubbleView.extractReferencedDocuments) and the TTS preprocessor
        // strip the block by matching that literal tag, so attributes on it would leak
        // the raw XML into the rendered message. Keep guidance in a child element.
        var lines = [
            "<referenced-documents>",
            "  <instructions>The user attached these library documents as context. "
            + "Their full text is NOT included below — only metadata. To read a "
            + "document's content, call the oak tool: `items read \"&lt;title-or-cite-key&gt;\" "
            + "[--pages N-M]`. To find a passage inside one, use `search &lt;query&gt;`. "
            + "Read the referenced document(s) with the tool before answering questions "
            + "about them — do not ask the user to summarize or open them for you.</instructions>"
        ]
        for ref in libraryRefs {
            // Prefer a real cite-key (resolvable by `oak items read`); fall back to the
            // title, which the resolver also matches exactly. Never emit the storageKey
            // as cite-key — it is a storage path, not a resolvable identifier.
            let readKey = ref.citeKey ?? ref.title
            var attrs =
                "title=\"\(xmlEsc(ref.title))\" "
                + "author=\"\(xmlEsc(ref.author))\" pages=\"\(ref.pageCount)\" "
                + "format=\"\(xmlEsc(ref.contentType))\" "
                + "read-with=\"items read &quot;\(xmlEsc(readKey))&quot;\""
            if let ck = ref.citeKey, !ck.isEmpty {
                attrs = "cite-key=\"\(xmlEsc(ck))\" " + attrs + " link=\"oak://cite/\(xmlEsc(ck))\""
            }
            lines.append("  <doc \(attrs) />")
        }
        lines.append("</referenced-documents>")
        return lines.joined(separator: "\n")
    }

    private static func xmlEsc(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Agent Skills

    private static func loadAgentSkills() -> [AgentSkill] {
        // Only load installed skills from the shared SkillManager directory.
        SkillLoader.loadSkills(from: [SkillManager.installedDir], source: .user).skills
    }

    // MARK: - Private — Session Persistence

    private func persistSessionMetadata(firstUserMessage: String) {
        guard let service = sessionService else { return }

        if !sessionRecordCreated {
            // First message in this session — create the DB record
            let title = String(firstUserMessage.prefix(50))
            try? service.createSession(id: sessionId, title: title, itemId: itemId)
            sessionRecordCreated = true
        } else {
            // Subsequent messages — update count and timestamp
            let messageCount = turns.filter { !$0.isStreaming }.count + 1 // +1 for this message
            let title = turns.first(where: { $0.role == .user })?.content.prefix(50).description
                ?? firstUserMessage.prefix(50).description
            try? service.updateSession(id: sessionId, title: title, messageCount: messageCount)
        }
    }
}

