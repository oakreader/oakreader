import SwiftUI
import WebKit

// MARK: - Custom WKWebView with context menu

/// WKWebView subclass that adds custom items to the right-click context menu.
final class OakWebView: WKWebView {
    weak var coordinator: WebViewCoordinator?

    // Cursor is controlled via CSS (`cursor: default` on html) so that
    // WebKit can still show pointer on links without fighting native overrides.

    // Trackpad pinch. WKWebView's native `magnification` is a bitmap scale of the
    // already-rendered page (no reflow → content overflows → horizontal scrollbar).
    // We disable that (`allowsMagnification = false`) and route the gesture to
    // `pageZoom` instead, which is browser-style full-page zoom: it enlarges text
    // and reflows responsive content to the window width.
    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        coordinator?.viewModel.viewer.setZoom(pageZoom * factor)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // "Open in Browser" for live link embeds. Region capture now lives in
        // the AI chat composer (Dia-style), so it's no longer a page menu item.
        if coordinator?.isLiveMode == true {
            menu.addItem(.separator())
            let openItem = NSMenuItem(
                title: "Open in Browser",
                action: #selector(openInBrowser),
                keyEquivalent: ""
            )
            openItem.target = self
            openItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
            menu.addItem(openItem)
        }
    }

    @objc private func openInBrowser() {
        guard let url = coordinator?.webView?.url ?? coordinator?.viewModel.liveURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - NSViewRepresentable

/// NSViewRepresentable wrapper around WKWebView for rendering HTML documents.
struct HTMLViewerRepresentable: NSViewRepresentable {
    let viewModel: DocumentViewModel

    @Environment(\.isTabActive) private var isTabActive

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(viewModel: viewModel)
    }

    /// Login-form detection / capture / autofill, injected into live web pages.
    static let passwordManagerScript = """
    (function() {
        function pwField() { return document.querySelector('input[type="password"]'); }
        function userField(pw) {
            if (!pw) return null;
            var form = pw.form || document;
            var pref = form.querySelectorAll('input[autocomplete="username"], input[type="email"], input[name*="user" i], input[name*="email" i], input[id*="user" i], input[id*="email" i]');
            for (var i = 0; i < pref.length; i++) {
                if (pref[i].type !== 'password' && pref[i].offsetParent !== null) return pref[i];
            }
            var inputs = form.querySelectorAll('input');
            var prev = null;
            for (var j = 0; j < inputs.length; j++) {
                if (inputs[j] === pw) break;
                var t = inputs[j].type;
                if (t === 'text' || t === 'email' || t === 'tel') prev = inputs[j];
            }
            return prev;
        }
        function setValue(el, val) {
            if (!el) return;
            el.focus();
            el.value = val;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        window.OakPasswords = {
            fill: function(username, password) {
                var pw = pwField();
                if (!pw) return;
                setValue(userField(pw), username);
                setValue(pw, password);
            }
        };
        function capture() {
            var pw = pwField();
            if (!pw || !pw.value) return;
            var u = userField(pw);
            try {
                window.webkit.messageHandlers.passwordManager.postMessage({
                    action: 'capture',
                    username: u ? u.value : '',
                    password: pw.value
                });
            } catch (e) {}
        }
        document.addEventListener('submit', capture, true);
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && e.target && e.target.type === 'password') capture();
        }, true);
    })();
    """

    func makeNSView(context: Context) -> OakWebView {
        let config = WKWebViewConfiguration()

        // Share a persistent data store across all live web views so cookies /
        // login state persist between tabs and across launches.
        config.websiteDataStore = BrowserSession.dataStore

        // Enable the HTML5 Fullscreen API (element.requestFullscreen) — WKWebView
        // disables it by default, which is why YouTube's fullscreen button no-ops.
        config.preferences.isElementFullscreenEnabled = true

        // Register text selection handler — sends text + bounding rect for popup positioning.
        // Uses requestAnimationFrame tracking to follow the selection during scroll/zoom,
        // since WKWebView on macOS may not reliably fire DOM scroll events.
        let selectionScript = WKUserScript(
            source: """
            (function() {
                var rafId = null;
                var lastKey = '';

                // True when the selection lives inside an editable field
                // (<input>, <textarea>, or contenteditable). The 划词 toolbar must
                // never cover a field the user is actively typing into.
                function isEditableContext(sel) {
                    var ae = document.activeElement;
                    if (ae) {
                        var tag = ae.tagName;
                        if (tag === 'INPUT' || tag === 'TEXTAREA' || ae.isContentEditable) {
                            return true;
                        }
                    }
                    if (sel && sel.rangeCount > 0) {
                        var node = sel.getRangeAt(0).commonAncestorContainer;
                        if (node && node.nodeType !== 1) node = node.parentElement;
                        while (node) {
                            var t = node.tagName;
                            if (t === 'INPUT' || t === 'TEXTAREA' || node.isContentEditable) {
                                return true;
                            }
                            node = node.parentElement;
                        }
                    }
                    return false;
                }

                function getSelectionInfo() {
                    var sel = window.getSelection();
                    if (isEditableContext(sel)) return null;
                    var text = sel.toString();
                    if (text && sel.rangeCount > 0) {
                        var range = sel.getRangeAt(0);
                        var rect = range.getBoundingClientRect();
                        var rects = range.getClientRects();
                        var topY = (rects.length > 0) ? rects[0].y : rect.y;
                        return {
                            text: text,
                            x: rect.x + rect.width / 2,
                            y: topY,
                            bottomY: rect.y + rect.height,
                            vpWidth: window.innerWidth,
                            vpHeight: window.innerHeight
                        };
                    }
                    return null;
                }

                function sendInfo(info) {
                    if (info) {
                        window.webkit.messageHandlers.textSelected.postMessage(info);
                    } else {
                        window.webkit.messageHandlers.textSelected.postMessage({text: ''});
                    }
                }

                function trackLoop() {
                    var info = getSelectionInfo();
                    if (info) {
                        var key = info.x + ',' + info.y + ',' + info.bottomY;
                        if (key !== lastKey) {
                            lastKey = key;
                            sendInfo(info);
                        }
                        rafId = requestAnimationFrame(trackLoop);
                    } else {
                        rafId = null;
                        lastKey = '';
                    }
                }

                function startTracking() {
                    if (rafId !== null) return;
                    rafId = requestAnimationFrame(trackLoop);
                }

                document.addEventListener('mouseup', function() {
                    var info = getSelectionInfo();
                    sendInfo(info);
                    if (info) startTracking();
                });

                // Authoritative dismiss signal: when the selection collapses to empty
                // (e.g. clicking into an input or anywhere in the page), tell the native
                // side to tear down the toolbar. Scroll never fires selectionchange nor
                // collapses the selection, so this won't flicker mid-scroll.
                document.addEventListener('selectionchange', function() {
                    var sel = window.getSelection();
                    if (!sel || sel.isCollapsed || sel.toString() === '') {
                        window.webkit.messageHandlers.textSelected.postMessage({ text: '', cleared: true });
                    }
                });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(selectionScript)
        config.userContentController.add(context.coordinator, name: "textSelected")

        // Custom selection overlay — hides native ::selection and renders
        // precise text-hugging highlight rects via getClientRects().
        let selectionOverlayScript = WKUserScript(
            source: """
            (function() {
                var style = document.createElement('style');
                style.textContent = [
                    '::selection { background-color: transparent !important; color: inherit !important; }',
                    '.oak-sel-rect { position: fixed; background-color: rgba(12,106,218,0.25);',
                    '  pointer-events: none; z-index: 2147483647; border-radius: 2px; }',
                    '@media (prefers-color-scheme: dark) {',
                    '  .oak-sel-rect { background-color: rgba(29,155,240,0.35); }',
                    '}'
                ].join('\\n');
                document.head.appendChild(style);

                var overlay = document.createElement('div');
                overlay.id = 'oak-sel-overlay';
                overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:2147483647;';
                document.body.appendChild(overlay);

                var rafId = 0;
                function renderSelectionRects() {
                    var sel = window.getSelection();
                    var hasSelection = sel && !sel.isCollapsed && sel.rangeCount > 0;
                    if (!hasSelection) {
                        if (overlay.firstChild) overlay.textContent = '';
                        return;
                    }
                    overlay.textContent = '';
                    var range = sel.getRangeAt(0);
                    var rects = range.getClientRects();
                    for (var i = 0; i < rects.length; i++) {
                        var r = rects[i];
                        if (r.width === 0 || r.height === 0) continue;
                        var div = document.createElement('div');
                        div.className = 'oak-sel-rect';
                        div.style.top = r.top + 'px';
                        div.style.left = r.left + 'px';
                        div.style.width = r.width + 'px';
                        div.style.height = r.height + 'px';
                        overlay.appendChild(div);
                    }
                }
                // Bail immediately while nothing is selected: no rAF is scheduled and
                // no DOM is touched, so plain scrolling stays on WebKit's async path.
                function scheduleRender() {
                    var sel = window.getSelection();
                    if (!sel || sel.isCollapsed) {
                        if (overlay.firstChild) overlay.textContent = '';
                        if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
                        return;
                    }
                    if (rafId) cancelAnimationFrame(rafId);
                    rafId = requestAnimationFrame(renderSelectionRects);
                }
                document.addEventListener('selectionchange', scheduleRender);
                // Passive + capture: lets WebKit scroll off the main thread.
                window.addEventListener('scroll', scheduleRender, { capture: true, passive: true });
                window.addEventListener('resize', scheduleRender, { passive: true });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(selectionOverlayScript)

        // Inject libraries: mark.js (text finder), web-highlighter + bridge (order matters),
        // and oak-cite-anchor (dom-anchor-text-quote → window.oakHighlightCitation for
        // fuzzy citation anchoring).
        let jsBundle = Bundle.main.resourceURL?
            .appendingPathComponent("Preview.bundle/js")
        for jsFile in ["mark.min.js", "web-highlighter.min.js", "oak-web-highlighter.js", "oak-cite-anchor.js"] {
            if let url = jsBundle?.appendingPathComponent(jsFile),
               let src = try? String(contentsOf: url, encoding: .utf8) {
                let script = WKUserScript(
                    source: src,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
                config.userContentController.addUserScript(script)
            }
        }
        config.userContentController.add(context.coordinator, name: "highlightEvent")
        config.userContentController.add(context.coordinator, name: "highlightContextMenu")
        config.userContentController.add(context.coordinator, name: "highlightFocus")

        // HTML snapshots (SingleFile captures) often bake in fixed pixel widths, so
        // even pageZoom would overflow horizontally. Inject fluid CSS so the page
        // wraps to the window width — zoom then only enlarges/reflows text
        // (browser-style) instead of producing a sideways scrollbar. Not for live
        // pages, which are already responsive.
        if viewModel.liveURL == nil {
            let fluidCSS = WKUserScript(
                source: """
                (function() {
                    var style = document.createElement('style');
                    style.textContent = [
                        'html, body { max-width: 100% !important; overflow-x: hidden !important; }',
                        'img, video, iframe { max-width: 100% !important; height: auto !important; }',
                        'table, pre, blockquote { max-width: 100% !important; }'
                    ].join('\\n');
                    (document.head || document.documentElement).appendChild(style);
                })();
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(fluidCSS)
        }

        // Password autofill — live web pages only. Detects login forms, captures
        // credentials on submit, and exposes OakPasswords.fill() for the coordinator
        // to populate saved credentials on load. Not injected for local snapshots.
        if viewModel.liveURL != nil {
            let pwScript = WKUserScript(
                source: Self.passwordManagerScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(pwScript)
            config.userContentController.add(context.coordinator, name: "passwordManager")

            // defuddle reader — defines window.oakExtractReadableMarkdown() so the chat
            // agent's read_current_page tool can extract the live page as readable markdown
            // (same extractor the web-clip extension uses). Live pages only.
            if let url = jsBundle?.appendingPathComponent("oak-defuddle.js"),
               let src = try? String(contentsOf: url, encoding: .utf8) {
                config.userContentController.addUserScript(WKUserScript(
                    source: src,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                ))
            }
        }

        let webView = OakWebView(frame: .zero, configuration: config)
        // Present a complete Safari UA so UA-sniffing sites (Google, YouTube, …)
        // serve their modern desktop layout instead of the legacy fallback.
        webView.customUserAgent = BrowserSession.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Disable native bitmap magnification — pinch is handled via pageZoom in
        // OakWebView.magnify(with:) so zoom reflows like a browser instead of
        // blowing up the rendered pixels and creating a horizontal scrollbar.
        webView.allowsMagnification = false
        #if DEBUG
        // Enables Safari Web Inspector (Develop ▸ <host>) → use the Timeline tab to
        // profile scrolling / main-thread work on live pages.
        webView.isInspectable = true
        #endif
        webView.coordinator = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.setupScrollMonitor()
        context.coordinator.setupNotificationObservers()
        context.coordinator.setupProgressObservation()
        context.coordinator.setupNavigationObservation()
        context.coordinator.setupBrowserCommandObservers()
        context.coordinator.setupSelectionInstrumentObservers()

        // Load content: remote URL for live link embeds, local file for HTML snapshots
        if let liveURL = viewModel.liveURL {
            webView.load(URLRequest(url: liveURL))
        } else if let snapshot = viewModel.html {
            let storageDir = snapshot.htmlURL.deletingLastPathComponent()
            webView.loadFileURL(snapshot.htmlURL, allowingReadAccessTo: storageDir)
        }

        return webView
    }

    func updateNSView(_ webView: OakWebView, context: Context) {
        context.coordinator.viewModel = viewModel

        // Install/remove global event monitors when tab becomes active/inactive
        context.coordinator.setActive(isTabActive)

        // Sync zoom level from toolbar controls
        let targetZoom = viewModel.state.zoomLevel
        if abs(webView.pageZoom - targetZoom) > 0.001 {
            webView.pageZoom = targetZoom
        }
    }
}
