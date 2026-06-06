import Foundation
import WebKit

/// WKNavigationDelegate + WKScriptMessageHandler for the HTML document viewer.
/// Blocks external navigation, handles text selection events from injected JS,
/// and shows a popup panel for selected text.
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var viewModel: DocumentViewModel
    weak var webView: WKWebView?

    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var headingObserver: NSObjectProtocol?
    private var findTextObserver: NSObjectProtocol?
    private var progressObservation: NSKeyValueObservation?
    private var navObservations: [NSKeyValueObservation] = []
    private var commandObservers: [NSObjectProtocol] = []
    private var selectionInstrumentObservers: [NSObjectProtocol] = []

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
    }

    /// Whether this coordinator is handling a live remote URL (link embed) vs local HTML.
    var isLiveMode: Bool { viewModel.liveURL != nil }

    deinit {
        removeMouseMonitor()
        removeScrollMonitor()
        removeNotificationObservers()
        progressObservation?.invalidate()
        navObservations.forEach { $0.invalidate() }
        commandObservers.forEach { NotificationCenter.default.removeObserver($0) }
        selectionInstrumentObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Active State

    /// Install or remove global event monitors when the tab becomes active/inactive.
    func setActive(_ active: Bool) {
        if active {
            if scrollMonitor == nil { setupScrollMonitor() }
            // Expose this page to the chat agent's `read_current_page` tool while it's frontmost.
            if isLiveMode, let webView { LivePageBridge.shared.setActiveWebView(webView) }
        } else {
            removeScrollMonitor()
            if let webView { LivePageBridge.shared.clearWebView(webView) }
        }
    }

    // MARK: - Notification Observers

    func setupNotificationObservers() {
        removeNotificationObservers()

        headingObserver = NotificationCenter.default.addObserver(
            forName: .webViewScrollToHeading,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let heading = notification.object as? String,
                  let webView = self?.webView else { return }
            let escapedHeading = heading
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            let js = """
            (function() {
                // Try by ID first (set by setupHeaderAnchors)
                var el = document.getElementById('\(escapedHeading)');
                if (!el) {
                    // Fallback: search heading text content
                    var headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
                    for (var i = 0; i < headings.length; i++) {
                        if (headings[i].textContent.trim() === '\(escapedHeading)') {
                            el = headings[i]; break;
                        }
                    }
                }
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                    // Briefly highlight the heading, matching the text-fragment cite.
                    document.querySelectorAll('.oak-cite-hl').forEach(function(n) {
                        n.classList.remove('oak-cite-hl');
                    });
                    el.classList.add('oak-cite-hl');
                    setTimeout(function() { el.classList.remove('oak-cite-hl'); }, 3000);
                }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        findTextObserver = NotificationCenter.default.addObserver(
            forName: .webViewFindText,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let text = notification.object as? String,
                  let webView = self?.webView else { return }
            let escapedText = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            // Use mark.js for cross-node, case-insensitive, whitespace-normalized
            // text matching. Temporarily wraps the first match in a <mark> element,
            // scrolls to it, then removes the wrapper after 3 seconds.
            let js = """
            (function() {
                var ctx = document.querySelector('.heti') || document.body;
                var instance = new Mark(ctx);
                // Remove any previous citation highlight.
                instance.unmark({ className: 'oak-cite-hl' });

                var scrolled = false;
                instance.mark('\(escapedText)', {
                    acrossElements: true,
                    caseSensitive: false,
                    separateWordSearch: false,
                    className: 'oak-cite-hl',
                    each: function(el) {
                        // Scroll only to the first <mark> element of the first match.
                        if (!scrolled) {
                            scrolled = true;
                            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                        }
                    },
                    noMatch: function() {
                        // Last resort: try the deprecated window.find for simple cases.
                        window.getSelection().removeAllRanges();
                        window.find('\(escapedText)', false, false, true);
                    },
                    done: function(count) {
                        if (count === 0) return;
                        // Remove the highlight after 3 seconds.
                        setTimeout(function() {
                            instance.unmark({ className: 'oak-cite-hl' });
                        }, 3000);
                    }
                });
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func removeNotificationObservers() {
        if let obs = headingObserver {
            NotificationCenter.default.removeObserver(obs)
            headingObserver = nil
        }
        if let obs = findTextObserver {
            NotificationCenter.default.removeObserver(obs)
            findTextObserver = nil
        }
    }

    // MARK: - Selection-instrument observers (HTML / live web side)

    /// Mirror of `PDFViewCoordinator.setupSelectionInstrumentObservers` for the
    /// web side. Selection text comes from `DocumentState.selectedText` (which
    /// the bridge script keeps in sync); highlight/underline dispatch to the
    /// OakHighlighter JS bridge — the same call the popup makes — so all three
    /// handles (popup / shortcut / toolbar) converge on one instrument.
    func setupSelectionInstrumentObservers() {
        removeSelectionInstrumentObservers()
        let center = NotificationCenter.default

        func observe(_ name: Notification.Name, _ handler: @escaping (String) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      (note.object as AnyObject) === self.viewModel,
                      let text = self.viewModel.state.selectedText,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                handler(text)
            }
            selectionInstrumentObservers.append(token)
        }

        observe(.selectionApplyHighlight) { [weak self] _ in
            self?.applyWebMarkup(type: "highlight")
        }
        observe(.selectionApplyUnderline) { [weak self] _ in
            self?.applyWebMarkup(type: "underline")
        }
        observe(.selectionAttachToChat) { [weak self] text in
            guard let self else { return }
            self.viewModel.chat.addTextAttachment(text, pageIndex: 0)
            self.viewModel.state.rightPanelMode = .aiChat
        }
        observe(.selectionTranslate) { [weak self] text in
            guard let self else { return }
            self.viewModel.translation.setSourceText(text)
            self.viewModel.state.rightPanelMode = .translation
        }
        observe(.selectionAskAI) { [weak self] text in
            guard let self else { return }
            self.viewModel.chat.addTextAttachment(text, pageIndex: 0)
            self.viewModel.state.rightPanelMode = .aiChat
        }
    }

    private func removeSelectionInstrumentObservers() {
        selectionInstrumentObservers.forEach { NotificationCenter.default.removeObserver($0) }
        selectionInstrumentObservers.removeAll()
    }

    /// Dispatch a markup creation to the OakHighlighter JS bridge using the
    /// currently-selected stroke color. JS reads the live DOM selection.
    private func applyWebMarkup(type: String) {
        guard let webView else { return }
        let cssColor = viewModel.annotation.strokeColor.hexString
        let escapedColor = cssColor.replacingOccurrences(of: "'", with: "\\'")
        let escapedType = type.replacingOccurrences(of: "'", with: "\\'")
        let js = "OakHighlighter.highlightSelection('\(escapedColor)', '\(escapedType)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
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
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Local HTML mode: allow file URLs, block external HTTP(S)
        guard isLiveMode else {
            let isExternalWeb = url.scheme == "http" || url.scheme == "https"
            decisionHandler(isExternalWeb ? .cancel : .allow)
            return
        }

        // Live mode acts as a real browser: navigate every HTTP(S) link in place.
        // The "Open in Browser" context-menu item remains the escape hatch to Safari.
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate

    /// `target="_blank"` / `window.open` links return no web view from us, so WebKit
    /// would silently drop them. Load the request in the current view instead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: - Navigation Lifecycle

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        viewModel.state.webLoadProgress = 1
        webView.evaluateJavaScript("OakHighlighter.init();") { [weak self] _, _ in
            self?.restoreSavedHighlights()
        }
        autofillSavedCredentials()
        extractTableOfContents()
    }

    // MARK: - Table of Contents

    /// Walks the live page's heading elements, tagging any without an id so the
    /// sidebar can scroll back to them, and mirrors the outline into DocumentState.
    private static let tocExtractionJS = """
    (function () {
      try {
        var nodes = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
        var out = [];
        var i = 0;
        for (var n = 0; n < nodes.length; n++) {
          var el = nodes[n];
          var style = window.getComputedStyle(el);
          if (!style || style.display === 'none' || style.visibility === 'hidden') continue;
          var text = (el.innerText || el.textContent || '').trim();
          if (!text) continue;
          if (text.length > 200) { text = text.substring(0, 200); }
          if (!el.id) { el.id = 'oak-toc-' + i; }
          out.push({ level: parseInt(el.tagName.substring(1), 10), title: text, elementId: el.id });
          i++;
        }
        return JSON.stringify(out);
      } catch (e) { return '[]'; }
    })();
    """

    private func extractTableOfContents() {
        guard isLiveMode, let webView else { return }
        webView.evaluateJavaScript(Self.tocExtractionJS) { [weak self] result, _ in
            guard let self else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let headings = try? JSONDecoder().decode([WebHeading].self, from: data) else {
                self.viewModel.state.tableOfContents = []
                return
            }
            self.viewModel.state.tableOfContents = headings
        }
    }

    /// Fill the first saved credential for the current host into the page's login form.
    private func autofillSavedCredentials() {
        guard isLiveMode, let webView, let host = webView.url?.host else { return }
        guard let cred = PasswordStore.credentials(for: host).first else { return }
        let user = cred.username
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let pass = cred.password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript(
            "if (window.OakPasswords) OakPasswords.fill('\(user)', '\(pass)');",
            completionHandler: nil
        )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    private func handleNavigationError(_ error: Error) {
        guard isLiveMode else { return }
        viewModel.state.webLoadProgress = 0
        viewModel.state.presentError("Failed to load page: \(error.localizedDescription)")
    }

    func setupProgressObservation() {
        guard isLiveMode, let webView else { return }
        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.viewModel.state.webLoadProgress = wv.estimatedProgress
            }
        }
    }

    /// Mirror WKWebView navigation state into DocumentState so the browser chrome
    /// (address bar, back/forward buttons) can bind to it.
    func setupNavigationObservation() {
        guard isLiveMode, let webView else { return }
        navObservations.forEach { $0.invalidate() }

        let urlObs = webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.viewModel.state.currentURL = wv.url }
        }
        let titleObs = webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
            DispatchQueue.main.async {
                let title = wv.title
                self?.viewModel.state.pageTitle = (title?.isEmpty == false) ? title : nil
            }
        }
        let backObs = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.viewModel.state.canGoBack = wv.canGoBack }
        }
        let fwdObs = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.viewModel.state.canGoForward = wv.canGoForward }
        }
        navObservations = [urlObs, titleObs, backObs, fwdObs]
    }

    /// Observe browser chrome commands. Notifications are scoped to this tab's
    /// view model via `object`, so multiple open browser tabs don't cross-fire.
    func setupBrowserCommandObservers() {
        guard isLiveMode else { return }
        commandObservers.forEach { NotificationCenter.default.removeObserver($0) }
        commandObservers = []

        func observe(_ name: Notification.Name, _ action: @escaping (WKWebView, Notification) -> Void) {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      (note.object as AnyObject) === self.viewModel,
                      let webView = self.webView else { return }
                action(webView, note)
            }
            commandObservers.append(token)
        }

        observe(.webViewGoBack) { wv, _ in wv.goBack() }
        observe(.webViewGoForward) { wv, _ in wv.goForward() }
        observe(.webViewReload) { wv, _ in wv.reload() }
        observe(.webViewStop) { wv, _ in wv.stopLoading() }
        observe(.webViewLoadURL) { wv, note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            wv.load(URLRequest(url: url))
        }
        observe(.webViewScrollToTOC) { wv, note in
            guard let elementId = note.userInfo?["id"] as? String else { return }
            let escaped = elementId
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var el = document.getElementById('\(escaped)');
                if (!el) return;
                el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                var prevOutline = el.style.outline;
                var prevOffset = el.style.outlineOffset;
                el.style.outline = '2px solid rgba(255,190,30,0.9)';
                el.style.outlineOffset = '2px';
                setTimeout(function() {
                    el.style.outline = prevOutline;
                    el.style.outlineOffset = prevOffset;
                }, 1600);
            })();
            """
            wv.evaluateJavaScript(js, completionHandler: nil)
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

        // Captured login credentials → offer to save if new or changed.
        if message.name == "passwordManager",
           let body = message.body as? [String: Any],
           body["action"] as? String == "capture",
           let username = body["username"] as? String,
           let password = body["password"] as? String,
           !password.isEmpty,
           let host = webView?.url?.host {
            if PasswordStore.needsSave(host: host, username: username, password: password) {
                viewModel.state.pendingPasswordSave = PendingPasswordSave(
                    host: host, username: username, password: password
                )
            }
            return
        }

        // Handle right-click on a highlight → show native context menu
        if message.name == "highlightContextMenu",
           let body = message.body as? [String: Any],
           let hlId = body["id"] as? String,
           let x = body["x"] as? CGFloat,
           let y = body["y"] as? CGFloat,
           let vpWidth = body["vpWidth"] as? CGFloat, vpWidth > 0,
           let vpHeight = body["vpHeight"] as? CGFloat, vpHeight > 0,
           let webView = self.webView {
            showHighlightContextMenu(
                highlightId: hlId, jsX: x, jsY: y,
                vpWidth: vpWidth, vpHeight: vpHeight, in: webView
            )
            return
        }

        guard message.name == "textSelected",
              let body = message.body as? [String: Any],
              let text = body["text"] as? String else {
            return
        }

        viewModel.state.selectedText = text.isEmpty ? nil : text

        // A genuine selection clear (collapsed selection, e.g. clicking into an input)
        // arrives flagged as `cleared` — dismiss the orphaned toolbar. Unflagged empty
        // messages are still ignored so the popup doesn't vanish when the selection
        // briefly clears mid-scroll; the mouse monitor handles outside-click dismissal.
        if text.isEmpty {
            if body["cleared"] as? Bool == true {
                HTMLSelectionPopupPanel.dismissCurrent()
                removeMouseMonitor()
            }
            return
        }

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
        // WKWebView is flipped (origin at top-left, Y down) matching JS viewport coords,
        // so no Y-flip is needed. Non-flipped views need bounds.height - y.
        let scaleX = webView.bounds.width / vpWidth
        let scaleY = webView.bounds.height / vpHeight
        let topViewY = webView.isFlipped ? y * scaleY : webView.bounds.height - y * scaleY
        let topViewPoint = NSPoint(x: x * scaleX, y: topViewY)
        let topWindowPoint = webView.convert(topViewPoint, to: nil)
        let topScreenPoint = window.convertPoint(toScreen: topWindowPoint)

        let bottomViewY = webView.isFlipped ? bottomY * scaleY : webView.bounds.height - bottomY * scaleY
        let bottomViewPoint = NSPoint(x: x * scaleX, y: bottomViewY)
        let bottomWindowPoint = webView.convert(bottomViewPoint, to: nil)
        let bottomScreenPoint = window.convertPoint(toScreen: bottomWindowPoint)

        // Reposition existing popup on scroll, or create new one
        if let popup = HTMLSelectionPopupPanel.current {
            popup.reposition(atTop: topScreenPoint, atBottom: bottomScreenPoint)
        } else {
            HTMLSelectionPopupPanel.show(
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

    // MARK: - Highlight Context Menu

    private func showHighlightContextMenu(
        highlightId: String, jsX: CGFloat, jsY: CGFloat,
        vpWidth: CGFloat, vpHeight: CGFloat, in webView: WKWebView
    ) {
        let scaleX = webView.bounds.width / vpWidth
        let scaleY = webView.bounds.height / vpHeight
        let viewY = webView.isFlipped ? jsY * scaleY : webView.bounds.height - jsY * scaleY
        let viewPoint = NSPoint(x: jsX * scaleX, y: viewY)

        let menu = NSMenu()
        let deleteItem = NSMenuItem(
            title: "Delete",
            action: #selector(deleteWebHighlight(_:)),
            keyEquivalent: ""
        )
        deleteItem.target = self
        deleteItem.representedObject = highlightId
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(deleteItem)

        menu.popUp(positioning: nil, at: viewPoint, in: webView)
    }

    @objc private func deleteWebHighlight(_ sender: NSMenuItem) {
        guard let hlId = sender.representedObject as? String else { return }
        // Remove from DOM
        let escapedId = hlId.replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("OakHighlighter.remove('\(escapedId)');", completionHandler: nil)
        // Soft-delete from DB
        guard let db = viewModel.database else { return }
        let store = AnnotationStore(database: db)
        store.softDelete(id: hlId)
    }

    // MARK: - Mouse Monitor (dismiss popup on outside click)

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // If the click is on the popup panel or its color sub-panel, let it through
            if let win = event.window,
               let popup = HTMLSelectionPopupPanel.current,
               popup.ownsWindow(win) {
                return event
            }
            // Otherwise dismiss the popup
            HTMLSelectionPopupPanel.dismissCurrent()
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

// MARK: - Notification Names

extension Notification.Name {
    static let webViewScrollToHeading = Notification.Name("webViewScrollToHeading")
    static let webViewFindText = Notification.Name("webViewFindText")

    // Browser chrome commands — posted with `object: viewModel` to scope to one tab.
    static let webViewGoBack = Notification.Name("webViewGoBack")
    static let webViewGoForward = Notification.Name("webViewGoForward")
    static let webViewReload = Notification.Name("webViewReload")
    static let webViewStop = Notification.Name("webViewStop")
    static let webViewLoadURL = Notification.Name("webViewLoadURL")
    static let webViewScrollToTOC = Notification.Name("webViewScrollToTOC")
}
