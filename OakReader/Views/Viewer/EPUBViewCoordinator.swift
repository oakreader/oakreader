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
                var totalWidth = document.body.scrollWidth;
                var pageWidth = window.innerWidth;
                var currentScroll = Math.round(window.scrollX);
                var maxScroll = totalWidth - pageWidth;
                if (currentScroll >= maxScroll - 2) {
                    return 'next_chapter';
                } else {
                    var target = Math.min(Math.round(currentScroll + pageWidth), maxScroll);
                    window.scrollTo({ left: target, top: 0, behavior: 'auto' });
                    return 'ok';
                }
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
                var currentScroll = Math.round(window.scrollX);
                if (currentScroll <= 2) {
                    return 'prev_chapter';
                } else {
                    var pageWidth = window.innerWidth;
                    var target = Math.max(Math.round(currentScroll - pageWidth), 0);
                    window.scrollTo({ left: target, top: 0, behavior: 'auto' });
                    return 'ok';
                }
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
            guard let self, self.pendingScrollToEnd else { return }
            self.pendingScrollToEnd = false
            webView.evaluateJavaScript("""
                window.scrollTo(document.body.scrollWidth - window.innerWidth, 0);
            """, completionHandler: nil)
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

    func loadSpineItem(at index: Int, scrollToEnd: Bool = false) {
        guard let epub = viewModel.epubDocument,
              let url = epub.contentURL(for: index),
              let webView = webView else { return }

        loadedSpineIndex = index
        pendingScrollToEnd = scrollToEnd
        webView.loadFileURL(url, allowingReadAccessTo: epub.contentDirectory)
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
