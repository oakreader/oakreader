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

    // MARK: - Page Load Complete

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("OakHighlighter.init();") { [weak self] _, _ in
            self?.restoreSavedHighlights()
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Handle highlight creation events from the bridge script
        if message.name == "highlightEvent",
           let body = message.body as? [String: Any],
           let action = body["action"] as? String,
           action == "create" {
            persistWebHighlight(body)
            return
        }

        guard message.name == "textSelected",
              let body = message.body as? [String: Any],
              let text = body["text"] as? String else {
            return
        }

        viewModel.state.selectedText = text.isEmpty ? nil : text

        // Don't dismiss popup on empty text — the mouse monitor handles dismissal on click.
        // This prevents the popup from vanishing during scroll when the selection briefly clears.
        guard !text.isEmpty,
              let x = body["x"] as? CGFloat,
              let y = body["y"] as? CGFloat,
              let bottomY = body["bottomY"] as? CGFloat,
              let vpWidth = body["vpWidth"] as? CGFloat, vpWidth > 0,
              let vpHeight = body["vpHeight"] as? CGFloat, vpHeight > 0,
              let webView = self.webView,
              let window = webView.window else {
            return
        }

        // Convert JS viewport coords to NSView coords using viewport-to-bounds scale.
        // This correctly handles pageZoom and magnification without manual zoom math.
        let scaleX = webView.bounds.width / vpWidth
        let scaleY = webView.bounds.height / vpHeight
        let topViewPoint = NSPoint(x: x * scaleX, y: webView.bounds.height - y * scaleY)
        let topWindowPoint = webView.convert(topViewPoint, to: nil)
        let topScreenPoint = window.convertPoint(toScreen: topWindowPoint)

        let bottomViewPoint = NSPoint(x: x * scaleX, y: webView.bounds.height - bottomY * scaleY)
        let bottomWindowPoint = webView.convert(bottomViewPoint, to: nil)
        let bottomScreenPoint = window.convertPoint(toScreen: bottomWindowPoint)

        // Reposition existing popup on scroll, or create new one
        if let popup = WebSelectionPopupPanel.current {
            popup.reposition(atTop: topScreenPoint, atBottom: bottomScreenPoint)
        } else {
            WebSelectionPopupPanel.show(
                atTop: topScreenPoint,
                atBottom: bottomScreenPoint,
                text: text,
                viewModel: viewModel,
                webView: webView,
                onDismiss: { [weak self] in
                    self?.removeMouseMonitor()
                }
            )
            installMouseMonitor()
        }
    }

    // MARK: - Web Highlight Persistence

    /// Persist a new highlight created via OakHighlighter to the annotation store.
    private func persistWebHighlight(_ body: [String: Any]) {
        guard let db = viewModel.database,
              let attId = viewModel.attachmentId,
              let itmId = viewModel.itemId else { return }

        guard let highlightId = body["id"] as? String,
              let color = body["color"] as? String,
              let type = body["type"] as? String,
              let sourcesJson = body["sources"] as? String else { return }

        // Extract text from the serialized sources for the annotation record
        var text: String?
        if let data = sourcesJson.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            text = dict["text"] as? String
        }

        let now = Date().iso8601String
        let store = AnnotationStore(database: db)
        let record = AnnotationRecord(
            id: highlightId,
            userId: localUserId,
            itemId: itmId,
            attachmentId: attId,
            key: AnnotationStore.generateKey(),
            type: type,
            authorName: nil,
            text: text,
            comment: nil,
            color: color,
            pageLabel: nil,
            sortIndex: "00000|000000|000000",
            positionKind: "web",
            positionJson: sourcesJson,
            styleJson: nil,
            source: "oakreader",
            sourceKey: nil,
            isExternal: false,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        store.upsert(record)
    }

    /// Restore all saved web highlights from the annotation store.
    private func restoreSavedHighlights() {
        guard let db = viewModel.database,
              let attId = viewModel.attachmentId else { return }

        let store = AnnotationStore(database: db)
        let records = store.fetch(attachmentId: attId)
            .filter { $0.positionKind == "web" && $0.deletedAt == nil }

        guard let webView, !records.isEmpty else { return }

        for record in records {
            let escapedJson = record.positionJson
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let escapedColor = record.color
                .replacingOccurrences(of: "'", with: "\\'")
            let escapedType = record.type
                .replacingOccurrences(of: "'", with: "\\'")

            let js = "OakHighlighter.restore('\(record.id)', '\(escapedJson)', '\(escapedColor)', '\(escapedType)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
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
