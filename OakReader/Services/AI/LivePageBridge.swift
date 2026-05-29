import Foundation
import WebKit

/// Sendable readable-content snapshot of a live web page.
struct ReadablePage: Sendable {
    let title: String
    let url: String
    let markdown: String
}

/// Bridges the chat agent's `read_current_page` tool to the live browser `WKWebView`.
///
/// Agent tools are `Sendable` and run off the main actor, while the web view is
/// main-thread + callback-based. This `@MainActor` singleton holds a weak handle to
/// the currently-active live web view (registered by `WebViewCoordinator`) and exposes
/// an async extractor that runs JS and returns a `Sendable` result — so a tool can just
/// `await LivePageBridge.shared.extractReadable()` with no main-thread or
/// Sendable-capture concerns.
@MainActor
final class LivePageBridge {
    static let shared = LivePageBridge()
    private init() {}

    private weak var activeWebView: WKWebView?

    /// Called by the active live-mode `WebViewCoordinator` when its tab is frontmost.
    func setActiveWebView(_ webView: WKWebView?) {
        activeWebView = webView
    }

    /// Clears the handle if `webView` is the one currently registered.
    func clearWebView(_ webView: WKWebView) {
        if activeWebView === webView { activeWebView = nil }
    }

    /// Whether a live page is currently available to read.
    var hasActivePage: Bool { activeWebView != nil }

    /// Extract the active live page as readable markdown. Prefers an injected
    /// `window.oakExtractReadableMarkdown()` (defuddle); falls back to `innerText`
    /// when that isn't present yet.
    func extractReadable(maxChars: Int = 8_000) async -> ReadablePage? {
        guard let webView = activeWebView else { return nil }
        let js = """
        (function () {
          try {
            if (typeof window.oakExtractReadableMarkdown === 'function') {
              return window.oakExtractReadableMarkdown();
            }
          } catch (e) {}
          var body = document.body ? document.body.innerText : '';
          return JSON.stringify({ title: document.title || '', url: location.href || '', markdown: body });
        })();
        """
        let value: Any? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: result)
            }
        }
        guard let json = value as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = (object["title"] as? String) ?? ""
        let url = (object["url"] as? String) ?? ""
        var markdown = (object["markdown"] as? String) ?? ""
        if markdown.count > maxChars {
            markdown = String(markdown.prefix(maxChars)) + "\n\n…[truncated]"
        }
        return ReadablePage(title: title, url: url, markdown: markdown)
    }
}
