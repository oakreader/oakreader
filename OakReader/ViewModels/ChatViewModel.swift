import Foundation
import OakAgent

struct PendingConfirmation {
    let toolCall: ToolCall
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
    var pendingAttachments: [TurnAttachment] = []
    var showSettings: Bool = false
    var errorMessage: String?
    var pendingToolConfirmation: PendingConfirmation?

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
    private let contextProvider = PDFContextProvider()
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
        return ProviderConfig(
            providerId: pid,
            model: prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel
        )
    }

    // MARK: - Send Message

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let attachments = pendingAttachments
        inputText = ""
        pendingAttachments = []
        isStreaming = true
        errorMessage = nil

        // Create or update session record in DB
        persistSessionMetadata(firstUserMessage: text)

        // Build enriched context snapshot
        let contextMode = selectedSkill?.contextMode ?? .currentPage
        let snapshot = PDFContextProvider.buildContextSnapshot(
            from: parent,
            appState: parent?.appState ?? appState,
            contextMode: contextMode
        )

        // Build system prompt from snapshot
        let currentSkill = selectedSkill
        let systemPrompt = PDFContextProvider.buildSystemPrompt(
            skill: currentSkill,
            context: snapshot
        )

        let currentHistory = turns.filter { !$0.isStreaming }
        let currentSessionId = sessionId
        let currentConfig = config
        let turnMetadata: [String: String] = currentSkill.map { ["skill": $0.id] } ?? [:]

        let prefs = Preferences.shared

        // Build tools list — document tools are always available when a document is open
        var tools: [any AgentTool] = []

        if let doc = snapshot.document {
            tools.append(ReadDocumentTool(
                filePath: doc.filePath,
                documentType: doc.itemType,
                pageCount: doc.pageCount
            ))
            tools.append(SearchDocumentTool(
                filePath: doc.filePath,
                documentType: doc.itemType,
                pageCount: doc.pageCount
            ))
            if !doc.noteSummaries.isEmpty {
                tools.append(ReadNotesTool(
                    notes: doc.noteSummaries.map { (id: $0.id.uuidString, title: $0.title) },
                    notesDirectory: CatalogDatabase.notesDirectory
                ))
            }
        }

        // Library-wide search tools — always available
        if let dbQueue = sessionService?.database.dbQueue {
            tools.append(SearchLibraryTool(dbQueue: dbQueue))
            tools.append(ReadLibraryItemTool(dbQueue: dbQueue))

            // Semantic search — available when index service is ready
            if let semanticService = appState?.semanticIndexService {
                tools.append(SemanticSearchTool(service: semanticService, dbQueue: dbQueue))
            }
        }

        // Academic web search — always available
        tools.append(AcademicSearchTool())

        // Existing filesystem agent tools (gated by preferences)
        if prefs.agentToolsEnabled, toolContext != nil {
            if prefs.agentReadFileEnabled { tools.append(ReadTool()) }
            if prefs.agentWriteFileEnabled { tools.append(WriteTool()) }
        }

        let currentTools: [any AgentTool]? = tools.isEmpty ? nil : tools

        // Ensure a tool context exists when document tools are present
        let effectiveToolContext: ToolExecutionContext?
        if !tools.isEmpty {
            let storagePath = parent?.itemStorageKey.map { CatalogDatabase.documentDirectory(storageKey: $0) }
            effectiveToolContext = toolContext ?? ToolExecutionContext(
                workingDirectory: storagePath ?? URL(fileURLWithPath: NSTemporaryDirectory()),
                allowedPaths: storagePath.map { [$0] } ?? []
            )
        } else {
            effectiveToolContext = nil
        }

        let requireConfirmation = prefs.agentRequireConfirmation

        // Load file-based agent skills from standard directories
        let agentSkills = Self.loadAgentSkills()

        streamTask = Task { @MainActor [weak self] in
            do {
                let stream = await engine.send(
                    userContent: text,
                    attachments: attachments,
                    history: currentHistory,
                    sessionId: currentSessionId,
                    config: currentConfig,
                    systemPrompt: systemPrompt,
                    turnMetadata: turnMetadata,
                    tools: currentTools,
                    toolContext: effectiveToolContext,
                    agentSkills: agentSkills,
                    toolConfirmation: requireConfirmation ? self?.makeToolConfirmation() : nil
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
                                isStreaming: true,
                                metadata: turnMetadata
                            )
                            assistantTurnId = newTurn.id
                            turns.append(newTurn)
                        }

                    case .toolUseStarted(let record):
                        if let id = assistantTurnId,
                           let idx = turns.lastIndex(where: { $0.id == id })
                        {
                            turns[idx].toolUses.append(record)
                        }

                    case .toolUsePending(let record):
                        if let id = assistantTurnId,
                           let idx = turns.lastIndex(where: { $0.id == id })
                        {
                            if let toolIdx = turns[idx].toolUses.firstIndex(where: { $0.id == record.id }) {
                                turns[idx].toolUses[toolIdx] = record
                            } else {
                                turns[idx].toolUses.append(record)
                            }
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

    private func makeToolConfirmation() -> @Sendable (ToolCall) async -> Bool {
        return { [weak self] call in
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let pending = PendingConfirmation(toolCall: call, continuation: continuation)
                DispatchQueue.main.async {
                    self?.pendingToolConfirmation = pending
                }
            }
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

    func removePendingAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: - Session Management

    func newSession() {
        turns = []
        sessionId = UUID()
        sessionRecordCreated = false
        selectedSkill = nil
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
                turns = try await engine.loadSession(id)
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

    // MARK: - Agent Skills

    private static func loadAgentSkills() -> [AgentSkill] {
        var dirs: [URL] = []

        // User-global skills directory
        let home = FileManager.default.homeDirectoryForCurrentUser
        let globalSkills = home.appendingPathComponent(".oakreader/skills")
        dirs.append(globalSkills)

        // Add skill directories from enabled plugins
        dirs.append(contentsOf: PluginService.shared.pluginSkillDirectories())

        return SkillLoader.loadSkills(from: dirs).skills
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
