import SwiftUI
import WebKit

// MARK: - Custom WKWebView with context menu

/// WKWebView subclass that adds an "Area Selection" toggle to the right-click context menu.
final class OakWebView: WKWebView {
    weak var coordinator: WebViewCoordinator?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        menu.addItem(.separator())

        let isAreaMode = coordinator?.viewModel.state.editorMode == .snapshot
        let areaItem = NSMenuItem(
            title: "Area Selection",
            action: #selector(toggleAreaSelection),
            keyEquivalent: ""
        )
        areaItem.target = self
        areaItem.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        areaItem.state = isAreaMode ? .on : .off
        menu.addItem(areaItem)
    }

    @objc private func toggleAreaSelection() {
        guard let vm = coordinator?.viewModel else { return }
        if vm.state.editorMode == .snapshot {
            vm.setEditorMode(.viewer)
        } else {
            vm.setEditorMode(.snapshot)
        }
    }
}

// MARK: - NSViewRepresentable

/// NSViewRepresentable wrapper around WKWebView for rendering web snapshots.
/// Security: blocks all external HTTP/HTTPS requests, scopes file access to storage directory only.
struct WebArchiveViewerRepresentable: NSViewRepresentable {
    let viewModel: DocumentViewModel

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> OakWebView {
        let config = WKWebViewConfiguration()

        // Register text selection handler — sends text + bounding rect for popup positioning
        let selectionScript = WKUserScript(
            source: """
            document.addEventListener('mouseup', function() {
                var sel = window.getSelection();
                var text = sel.toString();
                if (text && sel.rangeCount > 0) {
                    var rects = sel.getRangeAt(0).getClientRects();
                    if (rects.length > 0) {
                        var r = rects[0];
                        window.webkit.messageHandlers.textSelected.postMessage({
                            text: text, x: r.x + r.width / 2, y: r.y
                        });
                    } else {
                        var rect = sel.getRangeAt(0).getBoundingClientRect();
                        window.webkit.messageHandlers.textSelected.postMessage({
                            text: text, x: rect.x + rect.width / 2, y: rect.y
                        });
                    }
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

        let webView = OakWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.coordinator = context.coordinator
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

    func updateNSView(_ webView: OakWebView, context: Context) {
        context.coordinator.viewModel = viewModel

        // Sync zoom level from toolbar controls
        let targetZoom = viewModel.state.zoomLevel
        if abs(webView.pageZoom - targetZoom) > 0.001 {
            webView.pageZoom = targetZoom
        }
    }
}
