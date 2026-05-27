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
                anchor.heading = item.value?.removingPercentEncoding ?? item.value
            case "time":
                if let v = item.value, let t = Double(v) { anchor.time = t }
            case "text":
                anchor.text = item.value?.removingPercentEncoding ?? item.value
            default:
                break
            }
        }

        return (citeKey, anchor)
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

    // MARK: - Private

    private let engine: AgentSession
    private let contextProvider = LLMContextProvider()
    private var streamTask: Task<Void, Never>?
    /// Whether a DB record has been created for the current session.
    private var sessionRecordCreated: Bool = false
    /// Tool context for AI agent tool use (path sandbox).
    private var toolContext: ToolExecutionContext?

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

    // MARK: - Completion Items

    /// Items shown in the `/` slash completion panel.
    @MainActor
    var chatSlashItems: [ChatCompletionItem] {
        ChatCompletionItem.slashItems(
            installed: SkillManager.shared.installedSkills
        )
    }

    // MARK: - Send Message

    @MainActor
    func send() {
        let parsedInput = Self.extractLeadingSkillTags(from: inputText.trimmingCharacters(in: .whitespacesAndNewlines))
        let text = parsedInput.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !parsedInput.skillIds.isEmpty || !activeTokens.isEmpty else { return }

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

        // Extract library/note reference tokens and append XML block
        let libraryRefs = tokens.compactMap { token -> ChatCompletionItem.LibraryRefPayload? in
            if case .libraryReference(let p) = token.kind { return p }
            return nil
        }
        let noteRefs = tokens.compactMap { token -> ChatCompletionItem.NoteRefPayload? in
            if case .noteReference(let p) = token.kind { return p }
            return nil
        }
        if !libraryRefs.isEmpty || !noteRefs.isEmpty {
            userContent += "\n\n" + Self.buildReferencedDocumentsXML(
                libraryRefs: libraryRefs, noteRefs: noteRefs
            )
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

        // Build system prompt from snapshot
        let currentSkill = effectiveSkill
        let systemPrompt = LLMContextProvider.buildSystemPrompt(
            skill: currentSkill,
            context: snapshot
        )

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
        }

        // 2. Full-text content search (FTS5 over the indexed library), plus a
        //    research subagent for deep multi-document questions (its own loop).
        if let semanticService = appState?.semanticIndexService {
            tools.append(SemanticSearchTool(service: semanticService))
            tools.append(ResearchTool(searchService: semanticService, config: currentConfig))
        }

        // 3. Web search (always)
        tools.append(AcademicSearchTool())
        tools.append(WebSearchTool())
        tools.append(WebFetchTool())

        // 3b. Oak CLI (library search, read items, list collections/tags, manage library)
        tools.append(OakCLITool())

        // 3b-ii. Flashcards — render front/back cards inline as a carousel
        tools.append(QuizCardsTool())

        // 3c. Memory tools (always available for personalization)
        tools.append(UpdateMemoryTool())
        tools.append(UpdateUserProfileTool())
        tools.append(LogLearningTool())
        tools.append(PromoteMemoryTool())
        tools.append(SearchLearningLogTool())

        // 4. Filesystem tools (user preference gated)
        if prefs.agentToolsEnabled, toolContext != nil {
            if prefs.agentReadFileEnabled { tools.append(ReadTool()) }
            if prefs.agentWriteFileEnabled { tools.append(WriteTool()) }
            tools.append(BashTool())
        }

        // 5. ReadTool for notes (when document has notes or note references but ReadTool not already added)
        let hasNoteContext = snapshot.document?.notes.isEmpty == false || !noteRefs.isEmpty
        if hasNoteContext, !tools.contains(where: { $0.name == "read" }) {
            tools.append(ReadTool())
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
            effectiveToolContext = toolContext ?? ToolExecutionContext(
                workingDirectory: storagePath ?? URL(fileURLWithPath: NSTemporaryDirectory()),
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
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }

            isStreaming = false
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
                // Search for text within the PDF (optionally narrowed by page)
                Task { @MainActor in
                    await vm.viewer.search(query: text)
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

        case .video, .link, .audio:
            // Embed/link/audio documents have no in-place navigation target.
            break
        }
    }

    // MARK: - Stop Streaming

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false

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

    func newSession() {
        turns = []
        sessionId = UUID()
        sessionRecordCreated = false
        selectedSkill = nil
        activeTokens = []
        pendingAttachments = []
        inputText = ""
        errorMessage = nil
        showHistory = false
    }

    func loadSession(_ id: UUID) {
        sessionId = id
        sessionRecordCreated = true  // already exists in DB
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
        libraryRefs: [ChatCompletionItem.LibraryRefPayload],
        noteRefs: [ChatCompletionItem.NoteRefPayload]
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
        for ref in noteRefs {
            lines.append(
                "  <note title=\"\(xmlEsc(ref.title))\" path=\"\(xmlEsc(ref.path))\" />"
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

