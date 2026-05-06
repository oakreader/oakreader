import Foundation
import WebKit

/// WKNavigationDelegate + WKScriptMessageHandler for the EPUB viewer.
/// Handles text selection, internal EPUB link navigation, pagination, and Command+scroll zoom.
final class EPUBViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var viewModel: DocumentViewModel
    weak var webView: WKWebView?

    /// Tracks which spine index is currently loaded to avoid redundant reloads.
    var loadedSpineIndex: Int = -1
    /// Tracks navigation token to detect forced reloads from TOC clicks.
    var loadedNavigationToken: Int = 0
    /// When true, the next `didFinish` will scroll to the last page.
    private var pendingScrollToEnd: Bool = false
    /// Fragment identifier to scroll to after page load (e.g. "section2").
    private var pendingFragment: String?
    /// TOC label for heuristic heading search when no fragment exists.
    private var pendingSearchLabel: String?

    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var keyMonitor: Any?

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        removeMouseMonitor()
        removeScrollMonitor()
        removeKeyMonitor()
    }

    // MARK: - Setup

    func setupMonitors() {
        setupScrollMonitor()
        setupKeyMonitor()
    }

    private func setupScrollMonitor() {
        removeScrollMonitor()

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let webView = self.webView,
                  event.modifierFlags.contains(.command) else { return event }

            let locationInView = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(locationInView) else { return event }

            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return nil }

            let zoomFactor: CGFloat = 1.0 + (delta * 0.01)
            let newZoom = webView.pageZoom * zoomFactor
            self.viewModel.viewer.setZoom(newZoom)

            return nil
        }
    }

    private func setupKeyMonitor() {
        removeKeyMonitor()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let webView = self.webView else { return event }

            // Only handle when the web view's window is key
            guard webView.window?.isKeyWindow == true else { return event }

            let locationInView = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(locationInView) || webView.window?.firstResponder === webView else { return event }

            switch event.keyCode {
            case 123: // Left arrow
                self.pageBack()
                return nil
            case 124: // Right arrow
                self.pageForward()
                return nil
            case 125: // Down arrow
                self.pageForward()
                return nil
            case 126: // Up arrow
                self.pageBack()
                return nil
            case 49: // Space
                if event.modifierFlags.contains(.shift) {
                    self.pageBack()
                } else {
                    self.pageForward()
                }
                return nil
            case 121: // Page Down
                self.pageForward()
                return nil
            case 116: // Page Up
                self.pageBack()
                return nil
            case 115: // Home
                self.goToFirstChapter()
                return nil
            case 119: // End
                self.goToLastChapter()
                return nil
            default:
                return event
            }
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Pagination

    func pageForward() {
        guard let webView = webView else { return }
        webView.evaluateJavaScript("""
            (function() {
                var b = document.body;
                var pw = window.innerWidth;
                var maxPage = Math.round((b.scrollWidth - pw) / pw);
                var cur = Math.round(b.scrollLeft / pw);
                if (cur >= maxPage) return 'next_chapter';
                b.scrollLeft = (cur + 1) * pw;
                return 'ok';
            })();
        """) { [weak self] result, _ in
            if let action = result as? String, action == "next_chapter" {
                self?.goToNextChapter()
            }
        }
    }

    func pageBack() {
        guard let webView = webView else { return }
        webView.evaluateJavaScript("""
            (function() {
                var b = document.body;
                var pw = window.innerWidth;
                var cur = Math.round(b.scrollLeft / pw);
                if (cur <= 0) return 'prev_chapter';
                b.scrollLeft = (cur - 1) * pw;
                return 'ok';
            })();
        """) { [weak self] result, _ in
            if let action = result as? String, action == "prev_chapter" {
                self?.goToPreviousChapter()
            }
        }
    }

    private func goToNextChapter() {
        guard let epub = viewModel.epubDocument else { return }
        let next = viewModel.state.currentSpineIndex + 1
        if next < epub.spineItems.count {
            viewModel.state.currentSpineIndex = next
            loadSpineItem(at: next)
        }
    }

    private func goToPreviousChapter() {
        let prev = viewModel.state.currentSpineIndex - 1
        if prev >= 0 {
            viewModel.state.currentSpineIndex = prev
            loadSpineItem(at: prev, scrollToEnd: true)
        }
    }

    private func goToFirstChapter() {
        guard viewModel.epubDocument != nil else { return }
        viewModel.state.currentSpineIndex = 0
        loadSpineItem(at: 0)
    }

    private func goToLastChapter() {
        guard let epub = viewModel.epubDocument else { return }
        let last = epub.spineItems.count - 1
        guard last >= 0 else { return }
        viewModel.state.currentSpineIndex = last
        loadSpineItem(at: last)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let state = viewModel.state
        let js = EPUBViewerRepresentable.applySettingsJS(
            fontSize: state.epubFontSize,
            fontFamily: state.epubFontFamily,
            theme: state.epubTheme,
            margin: state.epubMargin,
            lineHeight: state.epubLineHeight
        )
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            guard let self else { return }
            if self.pendingScrollToEnd {
                self.pendingScrollToEnd = false
                webView.evaluateJavaScript("""
                    document.body.scrollLeft = document.body.scrollWidth - window.innerWidth;
                """, completionHandler: nil)
            } else if self.pendingFragment != nil || self.pendingSearchLabel != nil {
                let frag = self.pendingFragment
                let label = self.pendingSearchLabel
                self.pendingFragment = nil
                self.pendingSearchLabel = nil
                self.scrollToTarget(fragment: frag, searchLabel: label)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.isFileURL {
            if navigationAction.navigationType == .linkActivated {
                handleInternalLink(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }

        if url.scheme == "http" || url.scheme == "https" {
            decisionHandler(.cancel)
            return
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

        let viewPoint = NSPoint(x: x, y: webView.bounds.height - y)
        let windowPoint = webView.convert(viewPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        WebSelectionPopupPanel.show(
            at: screenPoint,
            text: text,
            viewModel: viewModel,
            onDismiss: { [weak self] in
                self?.removeMouseMonitor()
            }
        )
        installMouseMonitor()
    }

    // MARK: - Spine Navigation

    private func handleInternalLink(_ url: URL) {
        guard let epub = viewModel.epubDocument else { return }

        let clickedPath = url.path
        for (index, item) in epub.spineItems.enumerated() {
            guard let itemURL = epub.contentURL(for: index) else { continue }
            if clickedPath == itemURL.path || clickedPath.hasSuffix(item.path) {
                viewModel.state.currentSpineIndex = index
                loadSpineItem(at: index)
                return
            }
        }
    }

    func loadSpineItem(at index: Int, scrollToEnd: Bool = false, fragment: String? = nil, searchLabel: String? = nil) {
        guard let epub = viewModel.epubDocument,
              let url = epub.contentURL(for: index),
              let webView = webView else { return }

        // If same spine item is already loaded and we have a scroll target, scroll without reload
        if index == loadedSpineIndex && (fragment != nil || searchLabel != nil) {
            scrollToTarget(fragment: fragment, searchLabel: searchLabel)
            return
        }

        loadedSpineIndex = index
        pendingScrollToEnd = scrollToEnd
        pendingFragment = fragment
        pendingSearchLabel = searchLabel
        webView.loadFileURL(url, allowingReadAccessTo: epub.contentDirectory)
    }

    /// Scroll to a fragment ID or heuristically find a heading matching the label.
    /// Uses page-aligned scrolling compatible with CSS multi-column layout.
    private func scrollToTarget(fragment: String?, searchLabel: String?) {
        guard let webView = webView else { return }

        // Helper JS that finds an element and scrolls to its column page
        let scrollFn = """
        function __oak_scrollToElement(el) {
            if (!el) return false;
            var b = document.body;
            var pageWidth = window.innerWidth;
            var rect = el.getBoundingClientRect();
            var absLeft = rect.left + b.scrollLeft;
            var targetPage = Math.floor(absLeft / pageWidth);
            b.scrollLeft = targetPage * pageWidth;
            return true;
        }
        """

        let js: String
        if let frag = fragment, !frag.isEmpty {
            let escaped = frag.replacingOccurrences(of: "'", with: "\\'")
            js = """
            (function() {
                \(scrollFn)
                var el = document.getElementById('\(escaped)');
                if (__oak_scrollToElement(el)) return 'found';
                // Try name attribute fallback
                el = document.querySelector('[name="\(escaped)"]');
                if (__oak_scrollToElement(el)) return 'found';
                return 'not_found';
            })();
            """
        } else if let label = searchLabel, !label.isEmpty {
            let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            js = """
            (function() {
                \(scrollFn)
                var label = '\(escaped)';
                var cleanLabel = label.replace(/^\\d+\\.?\\s*/, '');
                var headings = document.querySelectorAll('h1, h2, h3, h4, h5, h6, [class*="heading"], [class*="chapter"], section[id]');
                // Exact match
                for (var i = 0; i < headings.length; i++) {
                    var text = headings[i].textContent.trim();
                    if (text === label || text === cleanLabel ||
                        text.toLowerCase() === cleanLabel.toLowerCase()) {
                        if (__oak_scrollToElement(headings[i])) return 'found:' + text;
                    }
                }
                // Partial match
                for (var i = 0; i < headings.length; i++) {
                    var text = headings[i].textContent.trim().toLowerCase();
                    if (text.indexOf(cleanLabel.toLowerCase()) >= 0 ||
                        cleanLabel.toLowerCase().indexOf(text) >= 0) {
                        if (__oak_scrollToElement(headings[i])) return 'partial:' + headings[i].textContent.trim();
                    }
                }
                return 'not_found';
            })();
            """
        } else {
            return
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Mouse Monitor

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window is WebSelectionPopupPanel {
                return event
            }
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
