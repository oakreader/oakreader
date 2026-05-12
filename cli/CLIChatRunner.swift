import Foundation
import OakAI
import PDFKit

struct CLIChatRunner {
    private let engine = ChatEngine(chatsDirectory: {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
    }())
    private let sessionId = UUID()

    // MARK: - One-shot mode

    func oneShot(filePath: String?, question: String) async throws {
        let config = loadConfig()
        let context = buildContext(filePath: filePath, contextMode: .fullDocument)

        print("Thinking...\n")

        let stream = await engine.send(
            userContent: question,
            attachments: [],
            history: [],
            sessionId: sessionId,
            config: config,
            skill: nil,
            pdfContext: context
        )

        for try await event in stream {
            switch event {
            case .delta(let text):
                print(text, terminator: "")
                fflush(stdout)
            case .toolUseStarted, .toolUsePending, .toolUseCompleted:
                break
            case .finished(let turn):
                if turn.role == .assistant && turn.content.isEmpty == false {
                    // Delta already printed the content
                }
            case .error(let error):
                fputs("\nError: \(error.localizedDescription)\n", stderr)
            }
        }
        print() // Final newline
    }

    // MARK: - Interactive mode

    func interactive(filePath: String?) async throws {
        let config = loadConfig()
        var history: [ChatTurn] = []

        if let path = filePath {
            print("Loaded: \(path)")
        }
        print("OakReader AI Chat (type 'quit' to exit, 'clear' to reset)")
        print("---")

        while true {
            print("\nYou: ", terminator: "")
            fflush(stdout)

            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !input.isEmpty else { continue }

            if input.lowercased() == "quit" || input.lowercased() == "exit" {
                print("Goodbye!")
                break
            }

            if input.lowercased() == "clear" {
                history = []
                print("Chat cleared.")
                continue
            }

            let context = buildContext(filePath: filePath, contextMode: .fullDocument)

            print("\nAssistant: ", terminator: "")
            fflush(stdout)

            let stream = await engine.send(
                userContent: input,
                attachments: [],
                history: history,
                sessionId: sessionId,
                config: config,
                skill: nil,
                pdfContext: context
            )

            do {
                for try await event in stream {
                    switch event {
                    case .delta(let text):
                        print(text, terminator: "")
                        fflush(stdout)
                    case .toolUseStarted, .toolUsePending, .toolUseCompleted:
                        break
                    case .finished(let turn):
                        if turn.role == .user {
                            history.append(turn)
                        } else if turn.role == .assistant {
                            history.append(turn)
                        }
                    case .error(let error):
                        fputs("\nError: \(error.localizedDescription)\n", stderr)
                    }
                }
                print() // Final newline
            } catch {
                fputs("\nError: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    // MARK: - Helpers

    private func loadConfig() -> ProviderConfig {
        let defaults = UserDefaults.standard
        let providerId = defaults.string(forKey: "aiProvider") ?? "anthropic"
        let defaultModel = ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? ""
        let model = defaults.string(forKey: "aiModel") ?? defaultModel

        return ProviderConfig(
            providerId: providerId,
            model: model.isEmpty ? defaultModel : model
        )
    }

    private func buildContext(filePath: String?, contextMode: ContextMode) -> PDFContextSnapshot? {
        guard let path = filePath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let doc = PDFDocument(url: url) else {
            fputs("Warning: Could not open PDF at \(path)\n", stderr)
            return nil
        }

        let pageCount = doc.pageCount
        let currentPageText = doc.page(at: 0)?.string ?? ""

        var fullText: String? = nil
        if contextMode == .fullDocument {
            let allText = (0..<pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n\n")
            fullText = String(allText.prefix(32_000))
        }

        return PDFContextSnapshot(
            fileName: url.lastPathComponent,
            pageCount: pageCount,
            currentPageIndex: 0,
            currentPageText: currentPageText,
            fullDocumentText: fullText
        )
    }
}
