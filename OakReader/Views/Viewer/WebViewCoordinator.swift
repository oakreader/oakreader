import Foundation
import WebKit

/// WKNavigationDelegate + WKScriptMessageHandler for the web snapshot viewer.
/// Blocks external navigation, handles text selection events from injected JS,
/// and shows a popup panel for selected text.
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var viewModel: DocumentViewModel
    weak var webView: WKWebView?

    private var mouseMonitor: Any?
    private var scrollMonitor: Any?

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        removeMouseMonitor()
        removeScrollMonitor()
    }

    // MARK: - Setup

    func setupScrollMonitor() {
        removeScrollMonitor()

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let webView = self.webView,
                  event.modifierFlags.contains(.command) else { return event }

            // Only handle events within the web view
            let locationInView = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(locationInView) else { return event }

            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return nil }

            // Smooth zoom factor proportional to scroll delta
            let zoomFactor: CGFloat = 1.0 + (delta * 0.01)
            let newZoom = webView.pageZoom * zoomFactor
            self.viewModel.viewer.setZoom(newZoom)

            return nil // Consume the event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
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
        guard message.name == "textSelected",
              let body = message.body as? [String: Any],
              let text = body["text"] as? String else {
            return
        }

        viewModel.state.selectedText = text.isEmpty ? nil : text

        guard !text.isEmpty,
              let x = body["x"] as? CGFloat,
              let y = body["y"] as? CGFloat,
              let webView = self.webView,
              let window = webView.window else {
            WebSelectionPopupPanel.dismissCurrent()
            removeMouseMonitor()
            return
        }

        // Convert content-relative coords (JS getBoundingClientRect) to screen coords.
        // JS coords are relative to the WKWebView's visible viewport, Y-down.
        // NSView coords are Y-up from the view's bottom.
        // CSS pixels -> view points (pageZoom scales the CSS coordinate space)
        let zoom = webView.pageZoom
        let viewPoint = NSPoint(x: x * zoom, y: webView.bounds.height - y * zoom)
        let windowPoint = webView.convert(viewPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        WebSelectionPopupPanel.show(
            at: screenPoint,
            text: text,
            viewModel: viewModel,
            webView: webView,
            onDismiss: { [weak self] in
                self?.removeMouseMonitor()
            }
        )
        installMouseMonitor()
    }

    // MARK: - Mouse Monitor (dismiss popup on outside click)

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // If the click is on the popup panel or its color sub-panel, let it through
            if let win = event.window,
               let popup = WebSelectionPopupPanel.current,
               popup.ownsWindow(win) {
                return event
            }
            // Otherwise dismiss the popup
            WebSelectionPopupPanel.dismissCurrent()
            self?.removeMouseMonitor()
            return event
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }
}
