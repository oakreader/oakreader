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

        // Register text selection handler — sends text + bounding rect for popup positioning
        let selectionScript = WKUserScript(
            source: """
            document.addEventListener('mouseup', function() {
                var sel = window.getSelection();
                var text = sel.toString();
                if (text && sel.rangeCount > 0) {
                    var rect = sel.getRangeAt(0).getBoundingClientRect();
                    window.webkit.messageHandlers.textSelected.postMessage({
                        text: text, x: rect.x + rect.width / 2, y: rect.y + rect.height
                    });
                } else {
                    window.webkit.messageHandlers.textSelected.postMessage({text: '', x: 0, y: 0});
                }
            });
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(selectionScript)
        config.userContentController.add(context.coordinator, name: "textSelected")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        context.coordinator.webView = webView
        context.coordinator.setupScrollMonitor()

        // Block all external network requests via content rule list (async to avoid deadlock)
        let ruleJSON = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "BlockExternal",
            encodedContentRuleList: ruleJSON
        ) { [weak webView] list, _ in
            DispatchQueue.main.async {
                guard let webView, let ruleList = list else { return }
                webView.configuration.userContentController.add(ruleList)
            }
        }

        // Load the HTML snapshot
        if let snapshot = viewModel.webSnapshot {
            let storageDir = snapshot.htmlURL.deletingLastPathComponent()
            webView.loadFileURL(snapshot.htmlURL, allowingReadAccessTo: storageDir)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.viewModel = viewModel

        // Sync zoom level from toolbar controls
        let targetZoom = viewModel.state.zoomLevel
        if abs(webView.pageZoom - targetZoom) > 0.001 {
            webView.pageZoom = targetZoom
        }
    }
}
