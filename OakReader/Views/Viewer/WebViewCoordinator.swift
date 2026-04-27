import Foundation
import WebKit

/// WKNavigationDelegate + WKScriptMessageHandler for the web snapshot viewer.
/// Blocks external navigation and handles text selection events from injected JS.
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var viewModel: DocumentViewModel

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Allow initial file load and same-document anchors
        if let url = navigationAction.request.url {
            if url.isFileURL {
                decisionHandler(.allow)
                return
            }
            // Block all external navigation — security parity with Zotero
            if url.scheme == "http" || url.scheme == "https" {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "textSelected", let text = message.body as? String {
            viewModel.state.selectedText = text.isEmpty ? nil : text
        }
    }
}
