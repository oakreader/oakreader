import Foundation
import OakReaderAI

@Observable
class ChatViewModel {
    weak var parent: DocumentViewModel?

    // MARK: - State

    var turns: [ChatTurn] = []
    var inputText: String = ""
    var isStreaming: Bool = false
    var selectedSkill: Skill? = nil
    var pendingAttachments: [ChatAttachment] = []
    var showSettings: Bool = false
    var errorMessage: String?

    // Session
    var sessionId: UUID = UUID()
    var sessions: [ChatSessionMeta] = []

    // MARK: - Private

    private let engine = ChatEngine()
    private let contextProvider = PDFContextProvider()
    private var streamTask: Task<Void, Never>?

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    // MARK: - Configuration

    var config: ProviderConfig {
        let prefs = Preferences.shared
        return ProviderConfig(
            provider: prefs.aiProvider,
            model: prefs.aiModel.isEmpty ? prefs.aiProvider.defaultModel : prefs.aiModel
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

        // Build PDF context
        let contextMode = selectedSkill?.contextMode ?? .currentPage
        let pdfContext: PDFContextSnapshot?
        if let parent {
            pdfContext = contextProvider.snapshot(from: parent, contextMode: contextMode)
        } else {
            pdfContext = nil
        }

        let currentHistory = turns.filter { !$0.isStreaming }
        let currentSessionId = sessionId
        let currentConfig = config
        let currentSkill = selectedSkill

        streamTask = Task { @MainActor in
            do {
                let stream = await engine.send(
                    userContent: text,
                    attachments: attachments,
                    history: currentHistory,
                    sessionId: currentSessionId,
                    config: currentConfig,
                    skill: currentSkill,
                    pdfContext: pdfContext
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
                            let newTurn = ChatTurn(
                                role: .assistant,
                                content: delta,
                                isStreaming: true,
                                skill: currentSkill?.id
                            )
                            assistantTurnId = newTurn.id
                            turns.append(newTurn)
                        }

                    case .finished(let turn):
                        if turn.role == .user {
                            turns.append(turn)
                        } else if let id = assistantTurnId,
                                  let idx = turns.lastIndex(where: { $0.id == id })
                        {
                            turns[idx].content = turn.content
                            turns[idx].isStreaming = false
                        } else {
                            var finalTurn = turn
                            finalTurn.isStreaming = false
                            turns.append(finalTurn)
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
        let attachment = ChatAttachment(
            type: .textSelection,
            label: "Page \(pageIndex + 1), selected text",
            textContent: text,
            pageIndex: pageIndex
        )
        pendingAttachments.append(attachment)
    }

    func addImageAttachment(_ imageData: Data, pageIndex: Int) {
        let attachment = ChatAttachment(
            type: .imageCapture,
            label: "Page \(pageIndex + 1), region capture",
            imageData: imageData,
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
        selectedSkill = nil
        pendingAttachments = []
        inputText = ""
        errorMessage = nil
    }

    func loadSession(_ id: UUID) {
        sessionId = id
        turns = []
        Task { @MainActor in
            do {
                turns = try await engine.loadSession(id)
            } catch {
                errorMessage = "Failed to load session: \(error.localizedDescription)"
            }
        }
    }

    func clearSession() {
        Task {
            await engine.deleteSession(sessionId)
        }
        turns = []
        errorMessage = nil
    }
}
