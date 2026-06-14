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
    /// Set by the `remember` tool and by background reflection; auto-clears.
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

    /// Background memory consolidation (USER.md profile + per-document brief).
    /// We only reflect once enough new material has accumulated, and never while
    /// a reflection is already running — see reflectIfDue().
    private var lastReflectedTurnCount = 0
    private var reflectionInFlight = false

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
    }

    init() {
        self.parent = nil
        self.engine = AgentSession(chatsDirectory: CatalogDatabase.chatsDirectory)
    }

    // MARK: - Configuration

    var config: ProviderConfig {
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        let defaultModel = ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
        let modelId = prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel
        let modelInfo = ProviderRegistry.shared.provider(for: pid)?.models.first { $0.id == modelId }
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

    /// Items shown in the `@`-mention panel: recent library documents the user can
    /// attach as context (the keyboard path to what drag-and-drop already does).
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
        let items = (try? store.fetchAllItems()) ?? []
        let recent = items.sorted { $0.dateAdded > $1.dateAdded }.prefix(60)
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

        // Build enriched context snapshot
        let contextMode = effectiveSkill?.contextMode ?? .currentPage
        let snapshot = LLMContextProvider.buildContextSnapshot(
            from: parent,
            appState: parent?.appState ?? appState,
            contextMode: contextMode
        )

        // Build system prompt from snapshot, appending the per-document continuity
        // brief (auto-summary of earlier chats about THIS item) when one exists.
        let currentSkill = effectiveSkill
        let baseSystemPrompt = LLMContextProvider.buildSystemPrompt(
            skill: currentSkill,
            context: snapshot
        )
        let systemPrompt: String
        if let item = itemId, let brief = LLMContextProvider.loadItemBrief(itemId: item) {
            systemPrompt = baseSystemPrompt + "\n\n" + brief
        } else {
            systemPrompt = baseSystemPrompt
        }

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

        // 3b-ii. Flashcards — render front/back cards inline as a carousel
        tools.append(QuizCardsTool())

        // 3c. Memory — explicit, user-directed lane only (view/add/update/remove).
        //     Passive capture happens automatically in the background (see
        //     reflectIfDue() / MemoryReflectionService); the model is told to use
        //     this tool ONLY when the user explicitly asks.
        tools.append(MemoryTool(itemId: itemId))

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

                for try await event in stream {
                    // The user switched/cleared/loaded a different session mid-stream.
                    // Stop before writing the old response into the new chat (and
                    // before flipping its `isStreaming`/indicator state).
                    if sessionId != currentSessionId { break }
                    switch event {
                    case .delta(let delta):
                        if let id = assistantTurnId,
                           let idx = turns.lastIndex(where: { $0.id == id })
                        {
                            turns[idx].content += delta
                        } else {
                            // First delta — create assistant turn placeholder
                            let newTurn = Turn(
                                role: .assistant,
                                content: delta,
                                isStreaming: true
                            )
                            assistantTurnId = newTurn.id
                            turns.append(newTurn)
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

                    case .toolInputDelta(let id, let name, let partialJSON):
                        // Stream the in-progress tool input so quiz cards render as
                        // they're generated. Only materialize a provisional record
                        // for quiz_cards (the only special inline renderer); the raw
                        // partial JSON is parsed leniently by the card view.
                        if name == "quiz_cards" {
                            let targetIdx: Int
                            if let aid = assistantTurnId,
                               let idx = turns.lastIndex(where: { $0.id == aid }) {
                                targetIdx = idx
                            } else {
                                let newTurn = Turn(role: .assistant, content: "", isStreaming: true)
                                assistantTurnId = newTurn.id
                                turns.append(newTurn)
                                targetIdx = turns.count - 1
                            }
                            let provisional = ToolUseRecord(
                                id: id, name: name,
                                input: ["_partial": .string(partialJSON)],
                                status: .executing
                            )
                            if let tIdx = turns[targetIdx].toolUses.firstIndex(where: { $0.id == id }) {
                                turns[targetIdx].toolUses[tIdx] = provisional
                            } else {
                                turns[targetIdx].toolUses.append(provisional)
                            }
                        }

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
                        if turn.role == .user {
                            turns.append(turn)
                        } else if let id = assistantTurnId,
                                  let idx = turns.lastIndex(where: { $0.id == id })
                        {
                            turns[idx].content = turn.content
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
                            finalTurn.isStreaming = false
                            turns.append(finalTurn)

                            if !turn.toolUses.isEmpty {
                                assistantTurnId = nil
                            }
                        }

                    case .error(let error):
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
            self?.reflectIfDue()
            self?.titleIfNeeded()
        }
    }

    // MARK: - Background Memory Reflection

    /// After a chat round settles, consolidate memory in the background if enough
    /// new material has accumulated. Off the hot path, fail-soft — never blocks or
    /// surfaces errors into the conversation.
    private func reflectIfDue() {
        guard Preferences.shared.memoryReflectionEnabled else { return }
        let settled = turns.filter { !$0.isStreaming && $0.role != .system }
        guard settled.count - lastReflectedTurnCount >= Preferences.shared.memoryReflectionFrequency else { return }
        runReflection(on: settled)
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

    /// When leaving a session (new/load), flush any unreflected material so the
    /// profile and brief capture the conversation we're walking away from.
    private func flushReflectionBeforeSwitch() {
        guard Preferences.shared.memoryReflectionEnabled else { return }
        let settled = turns.filter { !$0.isStreaming && $0.role != .system }
        guard settled.count > lastReflectedTurnCount, settled.count >= 2 else { return }
        runReflection(on: settled)
    }

    /// Config for the background reflection: the configured memory model (empty =
    /// inherit research/chat model), never extended thinking.
    private var memoryReflectionConfig: ProviderConfig {
        let model = Preferences.shared.memoryReflectionModel
        let base = researchConfig
        return ProviderConfig(
            providerId: base.providerId,
            model: model.isEmpty ? base.model : model,
            thinkingBudget: nil,
            thinkingEffort: nil
        )
    }

    private func runReflection(on settled: [Turn]) {
        guard !reflectionInFlight else { return }
        reflectionInFlight = true
        lastReflectedTurnCount = settled.count

        let prefs = Preferences.shared
        let cfg = memoryReflectionConfig
        let profilePrompt = prefs.memoryProfilePrompt.isEmpty
            ? MemoryReflectionService.defaultProfileSystem : prefs.memoryProfilePrompt
        let briefPrompt = prefs.memoryBriefPrompt.isEmpty
            ? MemoryReflectionService.defaultBriefSystem : prefs.memoryBriefPrompt
        let item = itemId

        Task.detached(priority: .background) { [weak self] in
            let service = MemoryReflectionService(
                config: cfg,
                profilePrompt: profilePrompt,
                briefPrompt: briefPrompt
            )
            var changes = await service.consolidateProfile(recentTurns: settled)
            if let item { changes += await service.updateItemBrief(itemId: item, recentTurns: settled) }
            let updated = changes
            await MainActor.run {
                self?.reflectionInFlight = false
                if updated > 0 { self?.flashMemoryNotice("Memory updated") }
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

    private func navigateInPlace(vm: DocumentViewModel, anchor: CitationAnchor) {
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
            if let heading = anchor.heading {
                NotificationCenter.default.post(
                    name: .webViewScrollToHeading, object: heading
                )
            } else if let text = anchor.text {
                NotificationCenter.default.post(
                    name: .webViewFindText, object: text
                )
            }

        case .link, .audio:
            // No in-place target — open the source platform at the timestamp.
            if let time = anchor.time, let source = vm.mediaDocument?.sourceURL {
                NSWorkspace.shared.open(MediaTimestampLink.url(forSource: source, atSeconds: time))
            }
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
        flushReflectionBeforeSwitch()
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
        lastReflectedTurnCount = 0
    }

    func loadSession(_ id: UUID) {
        cancelActiveStreamForSwitch()
        flushReflectionBeforeSwitch()
        sessionId = id
        sessionRecordCreated = true  // already exists in DB
        titleGenerated = true  // existing session already has a title; don't overwrite
        turns = []
        showHistory = false
        lastReflectedTurnCount = 0
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
        var lines = ["<referenced-documents>"]
        for ref in libraryRefs {
            let ck = ref.citeKey ?? ref.storageKey
            lines.append(
                "  <doc cite-key=\"\(xmlEsc(ck))\" title=\"\(xmlEsc(ref.title))\" "
                + "author=\"\(xmlEsc(ref.author))\" pages=\"\(ref.pageCount)\" "
                + "format=\"\(xmlEsc(ref.contentType))\" "
                + "link=\"oak://cite/\(xmlEsc(ck))\" />"
            )
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

