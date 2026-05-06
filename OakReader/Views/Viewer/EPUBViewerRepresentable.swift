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
    let navigationFragment: String?
    let navigationLabel: String?
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
            context.coordinator.loadSpineItem(
                at: targetIndex,
                fragment: navigationFragment,
                searchLabel: navigationLabel
            )
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
            var root = document.documentElement;
            root.style.setProperty('--oak-font-size', '\(fontSize)px');
            root.style.setProperty('--oak-font-family', '"\(fontFamily)", "Georgia", serif');
            root.style.setProperty('--oak-line-height', '\(lineHeight)');
            root.style.setProperty('--oak-margin', '\(margin)px');
            root.style.setProperty('--oak-bg-color', '\(theme.backgroundColor)');
            root.style.setProperty('--oak-text-color', '\(theme.textColor)');
            root.style.setProperty('--oak-link-color', '\(theme.linkColor)');
            root.style.setProperty('--oak-column-gap', '\(margin * 2)px');
            root.style.setProperty('--oak-td-clamp', '300px');
            root.setAttribute('data-oak-theme', '\(theme.rawValue)');
            root.setAttribute('data-oak-dark', '\(theme.isDark)');

            var style = document.createElement('style');
            style.id = 'oak-reader-style';
            style.textContent = `
                html {
                    height: 100%;
                    overflow: hidden;
                    -webkit-text-size-adjust: none;
                }
                body {
                    height: 100%;
                    margin: 0 !important;
                    padding: var(--oak-margin) var(--oak-margin) !important;
                    box-sizing: border-box;
                    font-family: var(--oak-font-family);
                    font-size: var(--oak-font-size);
                    line-height: var(--oak-line-height);
                    color: var(--oak-text-color);
                    background: var(--oak-bg-color) !important;
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                    -webkit-hyphens: auto;
                    -webkit-hyphenate-limit-before: 3;
                    -webkit-hyphenate-limit-after: 3;
                    -webkit-hyphenate-limit-lines: 2;
                    column-fill: auto;
                    column-gap: var(--oak-column-gap);
                    overflow: hidden;
                }
                a { color: var(--oak-link-color); }
                img, svg, video {
                    max-width: 100%;
                    max-height: 95%;
                    height: auto;
                    object-fit: contain;
                    box-sizing: border-box;
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
                td { max-width: var(--oak-td-clamp, 300px); }
                body::-webkit-scrollbar { display: none; }
            `;
            document.head.appendChild(style);

            var darkStyle = document.createElement('style');
            darkStyle.id = 'oak-dark-override';
            document.head.appendChild(darkStyle);

            window.__oak_applyColumns = function() {
                var b = document.body;
                var m = parseInt(getComputedStyle(root).getPropertyValue('--oak-margin')) || \(margin);
                var w = window.innerWidth;
                var h = window.innerHeight;
                b.style.columnWidth = (w - m * 2) + 'px';
                b.style.height = h + 'px';
                // Snap scroll position to nearest page boundary after layout recalculates
                requestAnimationFrame(function() {
                    var pw = window.innerWidth;
                    if (pw > 0) {
                        b.scrollLeft = Math.round(b.scrollLeft / pw) * pw;
                    }
                });
            };

            window.__oak_applyDarkOverrides = function() {
                var ds = document.getElementById('oak-dark-override');
                if (!ds) return;
                var isDark = root.getAttribute('data-oak-dark') === 'true';
                if (isDark) {
                    ds.textContent = `
                        * { background-color: transparent !important; }
                        html, body { background: var(--oak-bg-color) !important; }
                        body, p, div, span, li, td, th, dt, dd, blockquote, figcaption, cite {
                            color: var(--oak-text-color) !important;
                        }
                        a { color: var(--oak-link-color) !important; }
                        h1, h2, h3, h4, h5, h6 { color: var(--oak-text-color) !important; }
                    `;
                } else {
                    ds.textContent = '';
                }
            };

            window.__oak_applyColumns();
            window.__oak_applyDarkOverrides();
            window.addEventListener('resize', function() { window.__oak_applyColumns(); });
        })();
        """
    }

    static func applySettingsJS(fontSize: Int, fontFamily: String, theme: EPUBTheme, margin: Int, lineHeight: Double) -> String {
        """
        (function() {
            var root = document.documentElement;
            if (!root || !document.body) return;
            root.style.setProperty('--oak-font-size', '\(fontSize)px');
            root.style.setProperty('--oak-font-family', '"\(fontFamily)", "Georgia", serif');
            root.style.setProperty('--oak-line-height', '\(lineHeight)');
            root.style.setProperty('--oak-margin', '\(margin)px');
            root.style.setProperty('--oak-column-gap', '\(margin * 2)px');
            root.style.setProperty('--oak-bg-color', '\(theme.backgroundColor)');
            root.style.setProperty('--oak-text-color', '\(theme.textColor)');
            root.style.setProperty('--oak-link-color', '\(theme.linkColor)');
            root.setAttribute('data-oak-theme', '\(theme.rawValue)');
            root.setAttribute('data-oak-dark', '\(theme.isDark)');
            if (window.__oak_applyColumns) window.__oak_applyColumns();
            if (window.__oak_applyDarkOverrides) window.__oak_applyDarkOverrides();
        })();
        """
    }
}
