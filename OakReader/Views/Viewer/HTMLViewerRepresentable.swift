import SwiftUI
import WebKit

// MARK: - Custom WKWebView with context menu

/// WKWebView subclass that adds an "Area Selection" toggle to the right-click context menu.
final class OakWebView: WKWebView {
    weak var coordinator: WebViewCoordinator?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

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

/// NSViewRepresentable wrapper around WKWebView for rendering HTML snapshots.
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

        // Inject web-highlighter library + OakHighlighter bridge (order matters)
        let jsBundle = Bundle.main.resourceURL?
            .appendingPathComponent("Preview.bundle/js")
        for jsFile in ["web-highlighter.min.js", "oak-web-highlighter.js"] {
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

        // Disable WebKit's occlusion detection so it doesn't throttle
        // requestAnimationFrame/timers when the web view is hidden in the
        // tab ZStack (all tabs coexist but only one is visible at a time).
        DispatchQueue.main.async {
            if let window = webView.window {
                window.setValue(false, forKey: "windowOcclusionDetectionEnabled")
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

        // Install/remove global event monitors when tab becomes active/inactive
        context.coordinator.setActive(isTabActive)

        // Sync zoom level from toolbar controls
        let targetZoom = viewModel.state.zoomLevel
        if abs(webView.pageZoom - targetZoom) > 0.001 {
            webView.pageZoom = targetZoom
        }
    }
}
