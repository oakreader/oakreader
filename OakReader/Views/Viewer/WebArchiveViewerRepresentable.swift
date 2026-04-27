import SwiftUI
import WebKit

/// NSViewRepresentable wrapper around WKWebView for rendering web snapshots.
/// Security: blocks all external HTTP/HTTPS requests, scopes file access to storage directory only.
struct WebArchiveViewerRepresentable: NSViewRepresentable {
    let viewModel: DocumentViewModel

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Block all external network requests via content rule list
        let ruleJSON = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """
        let semaphore = DispatchSemaphore(value: 0)
        var contentRuleList: WKContentRuleList?
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "BlockExternal",
            encodedContentRuleList: ruleJSON
        ) { list, _ in
            contentRuleList = list
            semaphore.signal()
        }
        semaphore.wait()
        if let ruleList = contentRuleList {
            config.userContentController.add(ruleList)
        }

        // Register text selection handler
        let selectionScript = WKUserScript(
            source: """
            document.addEventListener('mouseup', function() {
                var sel = window.getSelection().toString();
                window.webkit.messageHandlers.textSelected.postMessage(sel);
            });
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(selectionScript)
        config.userContentController.add(context.coordinator, name: "textSelected")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Load the HTML snapshot
        if let snapshot = viewModel.webSnapshot {
            let storageDir = snapshot.htmlURL.deletingLastPathComponent()
            webView.loadFileURL(snapshot.htmlURL, allowingReadAccessTo: storageDir)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.viewModel = viewModel
    }
}
