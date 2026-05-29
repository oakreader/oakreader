import Foundation
import OakAgent

/// Reads the web page the user is currently viewing in browser mode, extracted as
/// clean readable markdown from the *live* (rendered, logged-in) DOM. Only registered
/// for `.link` documents (see `ChatViewModel.send`). Pulls content on demand via
/// `LivePageBridge` rather than eagerly dumping the page into every prompt.
struct ReadCurrentPageTool: AgentTool, Sendable {
    let name = "read_current_page"
    let description = """
        Read the web page the user is currently viewing in the browser, extracted as \
        clean readable markdown. This reads the LIVE, rendered, logged-in DOM — what the \
        user actually sees — not a fresh network fetch. Use it when the user's question \
        is about the page on screen ("this page", "what I'm reading", "summarize this"). \
        For other URLs use fetch_web_content instead, and never re-fetch the current \
        page's own URL with it.
        """

    var inputSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let page = await LivePageBridge.shared.extractReadable() else {
            return .error("No live web page is available to read right now.")
        }
        if page.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .error("The current page has no readable text content.")
        }
        let header = "# \(page.title)\nURL: \(page.url)\n\n"
        return .success(header + page.markdown)
    }
}
