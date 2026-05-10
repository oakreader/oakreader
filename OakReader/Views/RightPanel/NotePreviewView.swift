import SwiftUI
import WebKit

/// Rendered markdown preview using WKWebView with MiaoYan-style CSS typography.
/// Renders [[Page X]] references as tappable links and supports highlight.js,
/// KaTeX math, image zoom, and dark mode.
struct NotePreviewView: NSViewRepresentable {
    let content: String
    var baseURL: URL?
    var onReferenceClick: ((String) -> Void)?

    @AppStorage("noteEditorFontFamily") private var fontFamily = ".AppleSystemUIFont"
    @AppStorage("noteEditorFontSize") private var fontSize: Double = 16
    @AppStorage("noteEditorCodeFontFamily") private var codeFontFamily = "Iosevka Mono"
    @AppStorage("noteEditorAccentColor") private var accentColorHex: String = "#0CA69A"

    func makeCoordinator() -> Coordinator {
        Coordinator(onReferenceClick: onReferenceClick)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.add(context.coordinator, name: "oakRef")
        controller.add(context.coordinator, name: "checkbox")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        // Disable magnification bounce, allow scroll
        webView.allowsMagnification = false

        context.coordinator.webView = webView
        loadContent(into: webView, context: context)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update callback reference
        context.coordinator.onReferenceClick = onReferenceClick

        // Only reload if content or settings actually changed
        let isDark = isDarkMode()
        let currentHash = "\(content.hashValue)-\(isDark)-\(fontSize)-\(fontFamily)-\(codeFontFamily)-\(accentColorHex)"
        if currentHash != context.coordinator.lastContentHash {
            context.coordinator.lastContentHash = currentHash
            loadContent(into: webView, context: context)
        }
    }

    /// Cache directory for temporary HTML files.
    private static let previewCacheDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OakReaderPreview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func loadContent(into webView: WKWebView, context: Context) {
        let isDark = isDarkMode()
        let (cssFontFamily, fontFaceCSS) = Self.resolveFontForCSS(postScriptName: fontFamily)
        let (cssCodeFont, codeFontFaceCSS) = Self.resolveFontForCSS(postScriptName: codeFontFamily)
        let allFontFaceCSS = fontFaceCSS + codeFontFaceCSS
        let html = MarkdownRenderer.pageHTML(
            content: content,
            isDark: isDark,
            fontSize: Int(fontSize),
            fontFamily: cssFontFamily,
            codeFontFamily: cssCodeFont,
            fontFaceCSS: allFontFaceCSS,
            accentColor: accentColorHex,
            notesBaseURL: baseURL
        )

        // Rewrite CSS/JS paths to absolute file:// URLs pointing into the app bundle.
        // This allows loadFileURL with root access to find both bundle resources and
        // note images (which live in the user's documents/app support directory).
        guard let bundleURL = Bundle.main.url(
            forResource: "index", withExtension: "html", subdirectory: "Preview.bundle"
        )?.deletingLastPathComponent() else { return }

        var resolved = html
        resolved = resolved.replacingOccurrences(
            of: "href=\"css/", with: "href=\"\(bundleURL.absoluteString)css/")
        resolved = resolved.replacingOccurrences(
            of: "src=\"js/", with: "src=\"\(bundleURL.absoluteString)js/")

        // Write HTML to a temp file so we can use loadFileURL (grants filesystem access)
        let tempFile = Self.previewCacheDir.appendingPathComponent("preview.html")
        try? resolved.write(to: tempFile, atomically: true, encoding: .utf8)

        // Grant read access to "/" so WKWebView can load both bundle CSS/JS and note images
        webView.loadFileURL(tempFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    /// Resolve NSFont PostScript name to CSS font-family + @font-face if bundled.
    private static func resolveFontForCSS(postScriptName: String) -> (family: String, fontFace: String) {
        // System font: use CSS keyword (must not be quoted)
        if postScriptName.hasPrefix(".") {
            return ("-apple-system", "")
        }

        guard let font = NSFont(name: postScriptName, size: 16) else {
            return (postScriptName, "")
        }

        let familyName = font.familyName ?? postScriptName

        // Check if this font is bundled with the app (not a system font).
        // Xcode flattens Resources/Fonts/ → font files land at bundle root.
        let fontExtensions = ["ttf", "otf", "woff", "woff2"]
        for ext in fontExtensions {
            if let url = Bundle.main.url(forResource: postScriptName, withExtension: ext) {
                let fontFace = """
                @font-face {
                    font-family: "\(familyName)";
                    src: url("\(url.absoluteString)");
                }
                """
                return (familyName, fontFace)
            }
        }

        return (familyName, "")
    }

    private func isDarkMode() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onReferenceClick: ((String) -> Void)?
        var lastContentHash: String = ""
        weak var webView: WKWebView?
        private var scrollObserver: NSObjectProtocol?

        init(onReferenceClick: ((String) -> Void)?) {
            self.onReferenceClick = onReferenceClick
            super.init()
            scrollObserver = NotificationCenter.default.addObserver(
                forName: .markdownScrollToLine,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let index = notification.object as? Int,
                      let webView = self?.webView else { return }
                let js = """
                (function() {
                    var headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
                    if (headings.length > \(index)) {
                        headings[\(index)].scrollIntoView({ behavior: 'smooth', block: 'start' });
                    }
                })();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        deinit {
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "oakRef":
                if let reference = message.body as? String {
                    onReferenceClick?(reference)
                }
            case "checkbox":
                // Could be used for task list toggle in future
                break
            default:
                break
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

            // Handle oak-ref:// links
            if url.scheme == "oak-ref" {
                let reference = url.host ?? ""
                let decoded = reference.removingPercentEncoding ?? reference
                onReferenceClick?(decoded)
                decisionHandler(.cancel)
                return
            }

            // Open external links in default browser
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // Allow file:// and about: (initial load) and local navigation
            decisionHandler(.allow)
        }
    }
}
