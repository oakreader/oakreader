import SwiftUI
import WebKit

// MARK: - Custom WKWebView with context menu

/// WKWebView subclass that adds custom items to the right-click context menu.
final class OakWebView: WKWebView {
    weak var coordinator: WebViewCoordinator?

    // Cursor is controlled via CSS (`cursor: default` on html) so that
    // WebKit can still show pointer on links without fighting native overrides.

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        menu.addItem(.separator())

        // "Open in Browser" for live link embeds
        if coordinator?.isLiveMode == true {
            let openItem = NSMenuItem(
                title: "Open in Browser",
                action: #selector(openInBrowser),
                keyEquivalent: ""
            )
            openItem.target = self
            openItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
            menu.addItem(openItem)
        }

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

    @objc private func openInBrowser() {
        guard let url = coordinator?.webView?.url ?? coordinator?.viewModel.liveURL else { return }
        NSWorkspace.shared.open(url)
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

/// NSViewRepresentable wrapper around WKWebView for rendering HTML documents.
struct HTMLViewerRepresentable: NSViewRepresentable {
    let viewModel: DocumentViewModel

    @Environment(\.isTabActive) private var isTabActive

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> OakWebView {
        let config = WKWebViewConfiguration()

        // Register text selection handler — sends text + bounding rect for popup positioning.
        // Uses requestAnimationFrame tracking to follow the selection during scroll/zoom,
        // since WKWebView on macOS may not reliably fire DOM scroll events.
        let selectionScript = WKUserScript(
            source: """
            (function() {
                var rafId = null;
                var lastKey = '';

                function getSelectionInfo() {
                    var sel = window.getSelection();
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
                    overlay.textContent = '';
                    var sel = window.getSelection();
                    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return;
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
                function scheduleRender() {
                    cancelAnimationFrame(rafId);
                    rafId = requestAnimationFrame(renderSelectionRects);
                }
                document.addEventListener('selectionchange', scheduleRender);
                window.addEventListener('scroll', scheduleRender, true);
                window.addEventListener('resize', scheduleRender);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(selectionOverlayScript)

        // Inject libraries: mark.js (text finder), web-highlighter + bridge (order matters)
        let jsBundle = Bundle.main.resourceURL?
            .appendingPathComponent("Preview.bundle/js")
        for jsFile in ["mark.min.js", "web-highlighter.min.js", "oak-web-highlighter.js"] {
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

        let webView = OakWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.coordinator = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.setupScrollMonitor()
        context.coordinator.setupNotificationObservers()
        context.coordinator.setupProgressObservation()

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
