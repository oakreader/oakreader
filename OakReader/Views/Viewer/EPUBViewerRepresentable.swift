import SwiftUI
import WebKit

/// NSViewRepresentable wrapper around WKWebView for rendering EPUB spine items.
/// Uses CSS multi-column layout for page-based reading (like Apple Books).
/// Supports left/right arrow key page turning and chapter navigation via sidebar.
struct EPUBViewerRepresentable: NSViewRepresentable {
    let viewModel: DocumentViewModel

    // Stored value-type properties so SwiftUI detects changes and calls updateNSView.
    // These MUST be passed explicitly from the parent view's body.
    let currentSpineIndex: Int
    let navigationToken: Int
    let fontSize: Int
    let fontFamily: String
    let theme: EPUBTheme
    let margin: Int
    let lineHeight: Double
    let zoomLevel: CGFloat

    func makeCoordinator() -> EPUBViewCoordinator {
        EPUBViewCoordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Inject text selection handler
        let selectionScript = WKUserScript(
            source: """
            document.addEventListener('mouseup', function() {
                var sel = window.getSelection();
                var text = sel.toString();
                if (text && sel.rangeCount > 0) {
                    var rect = sel.getRangeAt(0).getBoundingClientRect();
                    window.webkit.messageHandlers.textSelected.postMessage({
                        text: text, x: rect.x + rect.width / 2, y: rect.y + rect.height
                    });
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

        // Inject paginated reader CSS + theme application function
        let state = viewModel.state
        let readerCSS = WKUserScript(
            source: Self.readerScript(
                fontSize: state.epubFontSize,
                fontFamily: state.epubFontFamily,
                theme: state.epubTheme,
                margin: state.epubMargin,
                lineHeight: state.epubLineHeight
            ),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(readerCSS)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.setupMonitors()

        // Block all external network requests
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

        // Load the initial spine item
        let initialIndex = state.currentSpineIndex
        if let epub = viewModel.epubDocument,
           let url = epub.contentURL(for: initialIndex) {
            context.coordinator.loadedSpineIndex = initialIndex
            webView.loadFileURL(url, allowingReadAccessTo: epub.contentDirectory)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.viewModel = viewModel

        // Sync zoom level
        let targetZoom = zoomLevel
        if abs(webView.pageZoom - targetZoom) > 0.001 {
            webView.pageZoom = targetZoom
        }

        // Navigate to a different spine item if the index or token changed
        let targetIndex = currentSpineIndex
        let token = navigationToken
        if targetIndex != context.coordinator.loadedSpineIndex ||
           token != context.coordinator.loadedNavigationToken {
            context.coordinator.loadedNavigationToken = token
            context.coordinator.loadSpineItem(at: targetIndex)
        }

        // Apply reader settings changes dynamically
        webView.evaluateJavaScript(
            Self.applySettingsJS(
                fontSize: fontSize,
                fontFamily: fontFamily,
                theme: theme,
                margin: margin,
                lineHeight: lineHeight
            ),
            completionHandler: nil
        )
    }

    // MARK: - Reader CSS/JS

    static func readerScript(fontSize: Int, fontFamily: String, theme: EPUBTheme, margin: Int, lineHeight: Double) -> String {
        """
        (function() {
            var style = document.createElement('style');
            style.id = 'oak-reader-style';
            style.textContent = `
                html {
                    height: 100%;
                    overflow: hidden;
                }
                body {
                    height: 100%;
                    margin: 0 !important;
                    padding: \(margin)px \(margin)px !important;
                    box-sizing: border-box;
                    font-family: "\(fontFamily)", "Georgia", serif;
                    font-size: \(fontSize)px;
                    line-height: \(lineHeight);
                    color: \(theme.textColor);
                    background: \(theme.backgroundColor) !important;
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                    column-fill: auto;
                    column-gap: 80px;
                    overflow-x: auto;
                    overflow-y: hidden;
                }
                a { color: \(theme.linkColor); }
                img, svg, video {
                    max-width: 100%;
                    max-height: 80vh;
                    height: auto;
                    page-break-inside: avoid;
                    break-inside: avoid;
                }
                pre, code {
                    white-space: pre-wrap;
                    word-wrap: break-word;
                }
                h1, h2, h3, h4, h5, h6 {
                    page-break-after: avoid;
                    break-after: avoid;
                }
                p { orphans: 2; widows: 2; }
                body::-webkit-scrollbar { display: none; }
            `;
            document.head.appendChild(style);

            function applyColumns() {
                var w = window.innerWidth;
                var h = window.innerHeight;
                document.body.style.columnWidth = (w - \(margin * 2)) + 'px';
                document.body.style.height = h + 'px';
            }
            applyColumns();
            window.addEventListener('resize', applyColumns);
        })();
        """
    }

    static func applySettingsJS(fontSize: Int, fontFamily: String, theme: EPUBTheme, margin: Int, lineHeight: Double) -> String {
        """
        (function() {
            var b = document.body;
            if (!b) return;
            b.style.fontSize = '\(fontSize)px';
            b.style.fontFamily = '"\(fontFamily)", "Georgia", serif';
            b.style.lineHeight = '\(lineHeight)';
            b.style.color = '\(theme.textColor)';
            b.style.background = '\(theme.backgroundColor)';
            b.style.padding = '\(margin)px \(margin)px';
            b.style.columnWidth = (window.innerWidth - \(margin * 2)) + 'px';
            var links = document.querySelectorAll('a');
            for (var i = 0; i < links.length; i++) {
                links[i].style.color = '\(theme.linkColor)';
            }
        })();
        """
    }
}
