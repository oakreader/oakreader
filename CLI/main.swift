import Foundation
import OakReaderAI

// Parse arguments
var filePath: String?
var question: String?

var i = 1
let args = CommandLine.arguments
while i < args.count {
    switch args[i] {
    case "--file", "-f":
        i += 1
        if i < args.count { filePath = args[i] }
    case "--ask", "-a":
        i += 1
        if i < args.count { question = args[i] }
    case "--help", "-h":
        let usage = """
        oakreader-chat — AI chat companion for PDF documents

        USAGE:
            oakreader-chat --file <path>                    Interactive mode
            oakreader-chat --file <path> --ask "question"   One-shot mode

        OPTIONS:
            -f, --file <path>      Path to PDF file
            -a, --ask <question>   Ask a question (one-shot mode)
            -h, --help             Show help
        """
        print(usage)
        exit(0)
    default:
        if filePath == nil && FileManager.default.fileExists(atPath: args[i]) {
            filePath = args[i]
        }
    }
    i += 1
}

let runner = CLIChatRunner()

let task = Task {
    do {
        if let question {
            try await runner.oneShot(filePath: filePath, question: question)
        } else {
            try await runner.interactive(filePath: filePath)
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Keep run loop alive for async
RunLoop.main.run()
