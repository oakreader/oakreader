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
    private var webSidebarObservers: [NSObjectProtocol] = []
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
                if (!document.getElementById('oak-cite-style')) {
                    var st = document.createElement('style');
                    st.id = 'oak-cite-style';
                    st.textContent = '.oak-cite-hl{background-color:rgba(255,214,10,0.45)!important;'
                        + 'border-radius:2px;transition:background-color .3s;}';
                    document.head.appendChild(st);
                }
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
            // Primary path: the bundled dom-anchor-text-quote hook (oak-cite-anchor.js)
            // fuzzily anchors the quote — handling the model's paraphrases/abbreviations
            // ("93 last month" vs the page's "93% a month") via diff-match-patch — then
            // flashes + scrolls to it. Fallback (bundle absent or no anchor found):
            // mark.js exact phrase, which still covers verbatim quotes.
            // Returns true when the quote was located (anchor or mark.js), false when
            // it could not be found — the native side then surfaces a toast so the
            // jump never fails silently.
            let js = """
            (function() {
                var query = '\(escapedText)';
                if (window.oakHighlightCitation &&
                    window.oakHighlightCitation(JSON.stringify({ exact: query }))) {
                    return true;
                }
                var ctx = document.querySelector('.heti') || document.body;
                var instance = new Mark(ctx);
                instance.unmark({ className: 'oak-cite-hl' });
                var scrolled = false;
                var hitCount = 0;
                instance.mark(query, {
                    acrossElements: true,
                    caseSensitive: false,
                    separateWordSearch: false,
                    ignorePunctuation: "\\"'’“”.,;:!?()%-",
                    className: 'oak-cite-hl',
                    each: function(el) {
                        if (!scrolled) {
                            scrolled = true;
                            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                        }
                    },
                    done: function(count) {
                        hitCount = count;
                        if (count === 0) return;
                        setTimeout(function() {
                            instance.unmark({ className: 'oak-cite-hl' });
                        }, 3000);
                    }
                });
                return hitCount > 0;
            })();
            """
            webView.evaluateJavaScript(js) { result, _ in
                guard (result as? Bool) == false else { return }
                Task { @MainActor in
                    showHUDToast(
                        message: "Couldn't find that quote on the page",
                        systemImage: "text.magnifyingglass",
                        tint: .secondaryLabelColor
                    )
                }
            }
        }

        setupWebSidebarObservers()
    }

    /// Observers for the web sidebar (live *and* snapshot), which share the same
    /// WKWebView. Covers the Search tab's find-in-page — unlike `.webViewFindText`
    /// (a one-shot cite jump that highlights and fades), these maintain a
    /// persistent set of `<mark>` matches the user can step through, reporting the
    /// count + current index into `DocumentState` — plus the Contents tab's
    /// scroll-to-heading. Both operate purely on the DOM, so they're ungated:
    /// only genuine browser commands (back/forward/reload) stay live-only.
    private func setupWebSidebarObservers() {
        let center = NotificationCenter.default

        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.object as AnyObject) === self.viewModel else { return }
                handler(note)
            }
            webSidebarObservers.append(token)
        }

        observe(.webViewFindInPage) { [weak self] note in
            let text = (note.userInfo?["text"] as? String) ?? ""
            self?.runWebFind(markJS(for: text))
        }
        observe(.webViewFindNext) { [weak self] _ in
            self?.runWebFind(stepJS(direction: 1))
        }
        observe(.webViewFindPrev) { [weak self] _ in
            self?.runWebFind(stepJS(direction: -1))
        }
        observe(.webViewClearFind) { [weak self] _ in
            self?.runWebFind(clearJS())
        }
        observe(.webViewScrollToTOC) { [weak self] note in
            guard let elementId = note.userInfo?["id"] as? String else { return }
            self?.scrollToTOCElement(elementId)
        }
        observe(.webViewFocusHighlight) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            let escaped = id.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            // Scrolls the highlight into view + flashes it, then posts `highlightFocus`
            // back so we can anchor the note editor to its final on-screen rect.
            self?.webView?.evaluateJavaScript("OakHighlighter.focusHighlight('\(escaped)');", completionHandler: nil)
        }
        observe(.webDeleteHighlight) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? String else { return }
            let escaped = id.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            self.webView?.evaluateJavaScript("OakHighlighter.remove('\(escaped)');", completionHandler: nil)
            if let db = self.viewModel.database {
                AnnotationStore(database: db).softDelete(id: id)
            }
        }
    }

    /// Smooth-scroll the web view to a heading captured by `extractTableOfContents`,
    /// flashing an outline so the target is easy to spot. Shared by live and snapshot.
    private func scrollToTOCElement(_ elementId: String) {
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
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Run a find script that returns `{count, current}` JSON and mirror it into
    /// `DocumentState` so the Search sidebar can render the status bar.
    private func runWebFind(_ js: String) {
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let str = result as? String,
                  let data = str.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return }
            self.viewModel.state.webSearchMatchCount = obj["count"] ?? 0
            self.viewModel.state.webSearchCurrentMatch = obj["current"] ?? 0
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
        webSidebarObservers.forEach { NotificationCenter.default.removeObserver($0) }
        webSidebarObservers.removeAll()
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
                  event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
            else { return event }

            // Only handle events within the web view
            let locationInView = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(locationInView) else { return event }

            // Trackpads report pixel-precise `scrollingDeltaY`; a traditional mouse
            // wheel leaves that at 0 and uses the line-based `deltaY` instead.
            let precise = event.hasPreciseScrollingDeltas
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            guard abs(delta) > 0.001 else { return nil }

            // Per-pixel step for trackpads; a larger per-detent step for mouse wheels.
            let step: CGFloat = precise ? 0.01 : 0.12
            let zoomFactor: CGFloat = 1.0 + (delta * step)
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

    /// Capture the main-frame response's MIME type so "Save to Reading List" can
    /// tell a PDF (e.g. arXiv `/pdf/<id>`, which has no `.pdf` suffix) from an HTML
    /// page and download the binary instead of bookmarking it. WebKit already has
    /// this from the loaded response — we just record it here.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame {
            let mime = navigationResponse.response.mimeType
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.state.currentMIMEType = mime
            }
        }
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

    /// Walks the page's heading elements, tagging any without an id so the
    /// sidebar can scroll back to them, and mirrors the outline into DocumentState.
    /// Runs for both live pages and local snapshots — both share the same DOM and
    /// the same Contents sidebar tab.
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
        guard let webView else { return }
        // A new page invalidates any prior find-in-page matches.
        viewModel.state.webSearchMatchCount = 0
        viewModel.state.webSearchCurrentMatch = 0
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
        // Note: `.webViewScrollToTOC` is registered in `setupWebSidebarObservers`
        // (ungated) so snapshots get heading navigation too.
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

        // A highlight asked to be focused (from the Notes sidebar) — it scrolled
        // itself into view and posted its rect; open the note editor anchored to it.
        // A highlight was clicked / focused from the sidebar — `focusHighlight`
        // already scrolled the page to it; open its note in the right panel.
        if message.name == "highlightFocus",
           let body = message.body as? [String: Any],
           let hlId = body["id"] as? String {
            openNoteInPanel(highlightId: hlId)
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

        let (topScreenPoint, bottomScreenPoint) = screenPoints(
            x: x, topY: y, bottomY: bottomY,
            vpWidth: vpWidth, vpHeight: vpHeight, webView: webView, window: window
        )

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

    // MARK: - Web Note Editor

    /// Convert a JS viewport rect (selection or highlight) to top/bottom screen
    /// points for anchoring a popup. WKWebView is flipped (origin top-left, Y down)
    /// matching JS viewport coords, so no Y-flip is needed there.
    func screenPoints(
        x: CGFloat, topY: CGFloat, bottomY: CGFloat,
        vpWidth: CGFloat, vpHeight: CGFloat, webView: WKWebView, window: NSWindow
    ) -> (top: NSPoint, bottom: NSPoint) {
        let scaleX = webView.bounds.width / vpWidth
        let scaleY = webView.bounds.height / vpHeight
        let topViewY = webView.isFlipped ? topY * scaleY : webView.bounds.height - topY * scaleY
        let topWindowPoint = webView.convert(NSPoint(x: x * scaleX, y: topViewY), to: nil)
        let top = window.convertPoint(toScreen: topWindowPoint)

        let bottomViewY = webView.isFlipped ? bottomY * scaleY : webView.bounds.height - bottomY * scaleY
        let bottomWindowPoint = webView.convert(NSPoint(x: x * scaleX, y: bottomViewY), to: nil)
        let bottom = window.convertPoint(toScreen: bottomWindowPoint)
        return (top, bottom)
    }

    /// Route a web highlight's note to the right-panel Notes stream (single
    /// surface). Reused by the highlight context menu and the click/sidebar focus
    /// flow. An existing note scrolls to + flashes its card; a fresh highlight
    /// (empty comment) starts an anchored compose.
    func openNoteInPanel(highlightId: String) {
        HTMLSelectionPopupPanel.dismissCurrent()
        viewModel.state.rightPanelMode = .comments
        let comment = viewModel.database.flatMap {
            AnnotationStore(database: $0).fetch(id: highlightId)?.comment
        }
        if (comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) {
            viewModel.comments.focusCard(id: highlightId)
        } else {
            viewModel.comments.startNote(forAnnotationId: highlightId)
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

            // Re-show the note marker for highlights that carry a comment.
            if let comment = record.comment,
               !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let escapedId = record.id.replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript("OakHighlighter.setHasNote('\(escapedId)', true);", completionHandler: nil)
            }
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

        // Does this highlight already carry a note? Drives the "Add" vs "Edit" label.
        let hasNote: Bool = {
            guard let db = viewModel.database,
                  let record = AnnotationStore(database: db).fetch(id: highlightId),
                  let comment = record.comment else { return false }
            return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()

        let menu = NSMenu()

        let noteItem = NSMenuItem(
            title: hasNote ? "Edit Note" : "Add Note",
            action: #selector(openWebHighlightNote(_:)),
            keyEquivalent: ""
        )
        noteItem.target = self
        // Stash the highlight id + its screen anchor for the note editor.
        let screenPoint = webView.window?.convertPoint(toScreen: webView.convert(viewPoint, to: nil)) ?? .zero
        noteItem.representedObject = WebNoteMenuContext(highlightId: highlightId, screenPoint: screenPoint)
        noteItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        menu.addItem(noteItem)

        menu.addItem(.separator())

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

    /// Carries a highlight + its screen anchor from the context menu to the editor.
    private final class WebNoteMenuContext: NSObject {
        let highlightId: String
        let screenPoint: NSPoint
        init(highlightId: String, screenPoint: NSPoint) {
            self.highlightId = highlightId
            self.screenPoint = screenPoint
        }
    }

    @objc private func openWebHighlightNote(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? WebNoteMenuContext else { return }
        openNoteInPanel(highlightId: ctx.highlightId)
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

    // Live-web find-in-page (Search sidebar tab) — posted with `object: viewModel`.
    // `webViewFindInPage` carries the query in `userInfo["text"]`.
    static let webViewFindInPage = Notification.Name("webViewFindInPage")
    static let webViewFindNext = Notification.Name("webViewFindNext")
    static let webViewFindPrev = Notification.Name("webViewFindPrev")
    static let webViewClearFind = Notification.Name("webViewClearFind")

    // Comments — posted with `object: viewModel`.
    // `commentsDidChange` tells the Comments panel to refresh after any comment is
    // added/edited/deleted (web popup, PDF popup, or the panel itself);
    // `webViewFocusHighlight` (carries `userInfo["id"]`) asks the web view to scroll
    // to + open the comment for a highlight; `webDeleteHighlight` (carries
    // `userInfo["id"]`) asks the web view to remove a highlight + soft-delete it.
    static let commentsDidChange = Notification.Name("commentsDidChange")
    static let webViewFocusHighlight = Notification.Name("webViewFocusHighlight")
    static let webDeleteHighlight = Notification.Name("webDeleteHighlight")
}

// MARK: - Find-in-page JavaScript

/// CSS injected once per page for the persistent find highlights. The base
/// match is a soft yellow; the active match is a stronger orange, mirroring a
/// browser's find bar.
private let oakFindStyle = """
mark.oak-find-hl{background:rgba(255,213,79,.45);color:inherit;border-radius:2px;}
mark.oak-find-current{background:rgba(255,138,0,.95);color:#000;}
"""

/// Escape a string for embedding inside a single-quoted JS literal.
private func jsEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
}

/// Mark every occurrence of `text`, activate the first match, and return
/// `{count, current}`. Uses mark.js without `acrossElements` so each match maps
/// to exactly one `<mark>` — keeping the count accurate and every match
/// individually navigable.
private func markJS(for text: String) -> String {
    let escaped = jsEscape(text)
    return """
    (function() {
        if (!document.getElementById('oak-find-style')) {
            var st = document.createElement('style');
            st.id = 'oak-find-style';
            st.textContent = '\(jsEscape(oakFindStyle))';
            document.head.appendChild(st);
        }
        var ctx = document.querySelector('.heti') || document.body;
        if (!window.__oakFindMark) { window.__oakFindMark = new Mark(ctx); }
        var inst = window.__oakFindMark;
        inst.unmark({ className: 'oak-find-hl' });
        window.__oakFindIdx = -1;
        var q = '\(escaped)';
        if (!q) { return JSON.stringify({ count: 0, current: 0 }); }
        inst.mark(q, {
            separateWordSearch: false,
            caseSensitive: false,
            acrossElements: false,
            className: 'oak-find-hl',
            done: function() {
                var marks = document.querySelectorAll('mark.oak-find-hl');
                if (marks.length) {
                    window.__oakFindIdx = 0;
                    marks[0].classList.add('oak-find-current');
                    marks[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
                }
            }
        });
        var count = document.querySelectorAll('mark.oak-find-hl').length;
        return JSON.stringify({ count: count, current: count ? 1 : 0 });
    })();
    """
}

/// Move the active match by `direction` (+1 / -1), wrapping around, and return
/// the refreshed `{count, current}`.
private func stepJS(direction: Int) -> String {
    """
    (function() {
        var marks = Array.prototype.slice.call(document.querySelectorAll('mark.oak-find-hl'));
        if (!marks.length) { return JSON.stringify({ count: 0, current: 0 }); }
        var idx = window.__oakFindIdx;
        if (idx == null || idx < 0) { idx = 0; }
        else { idx = (idx + (\(direction)) + marks.length) % marks.length; }
        window.__oakFindIdx = idx;
        marks.forEach(function(m, i) { m.classList.toggle('oak-find-current', i === idx); });
        marks[idx].scrollIntoView({ behavior: 'smooth', block: 'center' });
        return JSON.stringify({ count: marks.length, current: idx + 1 });
    })();
    """
}

/// Remove all find highlights and reset the counters.
private func clearJS() -> String {
    """
    (function() {
        if (window.__oakFindMark) { window.__oakFindMark.unmark({ className: 'oak-find-hl' }); }
        window.__oakFindIdx = -1;
        return JSON.stringify({ count: 0, current: 0 });
    })();
    """
}
