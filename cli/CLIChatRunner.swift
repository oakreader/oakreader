import Foundation
import OakAgent
import PDFKit

struct CLIChatRunner {
    private let engine = AgentSession(chatsDirectory: {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
    }())
    private let sessionId = UUID()

    // MARK: - One-shot mode

    func oneShot(filePath: String?, question: String) async throws {
        let config = loadConfig()
        let systemPrompt = buildSystemPrompt(filePath: filePath)

        print("Thinking...\n")

        let stream = await engine.send(
            userContent: question,
            attachments: [],
            history: [],
            sessionId: sessionId,
            config: config,
            systemPrompt: systemPrompt
        )

        for try await event in stream {
            switch event {
            case .delta(let text):
                print(text, terminator: "")
                fflush(stdout)
            case .thinkingDelta:
                break
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
        var history: [Turn] = []

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

            let systemPrompt = buildSystemPrompt(filePath: filePath)

            print("\nAssistant: ", terminator: "")
            fflush(stdout)

            let stream = await engine.send(
                userContent: input,
                attachments: [],
                history: history,
                sessionId: sessionId,
                config: config,
                systemPrompt: systemPrompt
            )

            do {
                for try await event in stream {
                    switch event {
                    case .delta(let text):
                        print(text, terminator: "")
                        fflush(stdout)
                    case .thinkingDelta:
                        break
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

    private func buildSystemPrompt(filePath: String?) -> String {
        var parts = ["You are a helpful AI assistant."]
        guard let path = filePath,
              let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return parts.joined(separator: "\n\n")
        }
        parts.append("Document: \"\(URL(fileURLWithPath: path).lastPathComponent)\" (\(doc.pageCount) pages).")
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n\n")
        parts.append("Document text:\n\"\"\"\n\(String(text.prefix(32_000)))\n\"\"\"")
        return parts.joined(separator: "\n\n")
    }
}
