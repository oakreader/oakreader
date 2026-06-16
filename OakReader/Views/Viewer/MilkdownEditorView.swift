import SwiftUI
import WebKit

/// A WYSIWYG Markdown editor embedded in a self-contained `WKWebView`, used for
/// the note/comment box on a highlight. The `oak-milkdown` bundle + its CSS from
/// `Preview.bundle` are inlined into a tiny HTML host; the note's markdown is
/// seeded after load via `window.oakMilkdown.init(...)`.
///
/// Every edit posts the serialized markdown back through `onMarkdownChanged`, so
/// the comment persists exactly as the plain-text `TextEditor` used to — storage
/// is unchanged (a markdown string in `AnnotationRecord.comment`).
///
/// Modeled on `StudioWebView` (the Mind Elixir host); see that file for the same
/// bundle-inlining pattern.
struct MilkdownEditorView: NSViewRepresentable {
    /// Markdown to seed the editor with (the note's current comment).
    let initialMarkdown: String
    /// Called with the full markdown on every edit.
    let onMarkdownChanged: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "oakMilkdown")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")  // blend into the popup material
        #if DEBUG
        webView.isInspectable = true
        #endif

        let coord = context.coordinator
        coord.onMarkdownChanged = onMarkdownChanged
        coord.seedMarkdown = initialMarkdown
        webView.navigationDelegate = coord
        webView.loadHTMLString(Self.html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // The editor owns its content after seeding — never push markdown back in
        // (that would clobber the user's in-progress edit). Only keep the callback
        // pointer fresh.
        context.coordinator.onMarkdownChanged = onMarkdownChanged
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onMarkdownChanged: ((String) -> Void)?
        var seedMarkdown = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let js = "window.oakMilkdown&&window.oakMilkdown.init(\(MilkdownEditorView.jsString(seedMarkdown)),true);"
            webView.evaluateJavaScript(js)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "oakMilkdown",
                  let body = message.body as? [String: Any],
                  let markdown = body["markdown"] as? String else { return }
            onMarkdownChanged?(markdown)
        }
    }

    // MARK: - HTML host

    /// Encode a Swift string as a JS string literal (quoted, escaped).
    static func jsString(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func bundleFile(_ name: String) -> String {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("Preview.bundle/js/\(name)"),
            let src = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return src
    }

    private static let html: String = {
        let css = bundleFile("oak-milkdown.css")
        let js = bundleFile("oak-milkdown.js")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        <style>
          html,body{margin:0;padding:0;height:100%;background:transparent;}
          #editor{height:100%;overflow-y:auto;}
          /* Tighten Crepe's frame theme for a small in-popup note surface. */
          .milkdown{background:transparent;}
          .milkdown .ProseMirror{padding:8px 12px;font-size:13px;}
        </style>
        </head><body><div id="editor"></div>
        <script>\(js)</script>
        </body></html>
        """
    }()
}
