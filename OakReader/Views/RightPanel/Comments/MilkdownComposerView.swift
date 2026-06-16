import SwiftUI
import WebKit

/// Imperative handle the flomo toolbar uses to drive the Milkdown editor running
/// inside the composer's `WKWebView` — toggle marks, wrap lists, insert a tag /
/// mention / image, and read back the markdown on send.
@MainActor
final class MilkdownComposerController {
    weak var webView: WKWebView?

    func cmd(_ name: String) { eval("window.oakMilkdown&&window.oakMilkdown.cmd('\(name)')") }
    func focus() { eval("window.oakMilkdown&&window.oakMilkdown.focus()") }
    func clear() { eval("window.oakMilkdown&&window.oakMilkdown.clear()") }

    func insertImage(_ url: String) {
        eval("window.oakMilkdown&&window.oakMilkdown.insertImage(\(MilkdownComposerView.jsString(url)))")
    }

    func getMarkdown(_ completion: @escaping (String) -> Void) {
        guard let webView else { completion(""); return }
        webView.evaluateJavaScript("window.oakMilkdown?window.oakMilkdown.getMarkdown():''") { result, _ in
            completion((result as? String) ?? "")
        }
    }

    private func eval(_ js: String) { webView?.evaluateJavaScript(js) }
}

/// The WYSIWYG Markdown editing surface — Milkdown Crepe in a `WKWebView`, with
/// the `oak-milkdown` bundle + CSS from `Preview.bundle` inlined into a tiny HTML
/// host. Seeds `initialMarkdown` after load; reports content height (for native
/// auto-grow), emptiness + char count, and ⌘↩ submit back through the
/// `oakMilkdown` message handler. Modeled on the (removed) MilkdownEditorView and
/// the Mind Elixir / cite-anchor `Preview.bundle` hosts.
struct MilkdownComposerView: NSViewRepresentable {
    let initialMarkdown: String
    let controller: MilkdownComposerController
    @Binding var isEmpty: Bool
    @Binding var charCount: Int
    @Binding var height: CGFloat
    var minHeight: CGFloat = 44
    var maxHeight: CGFloat = 220
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "oakMilkdown")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")   // blend into the card
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.navigationDelegate = context.coordinator
        context.coordinator.seedMarkdown = initialMarkdown
        webView.loadHTMLString(Self.html, baseURL: nil)
        controller.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MilkdownComposerView
        var seedMarkdown = ""
        init(_ parent: MilkdownComposerView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let js = "window.oakMilkdown&&window.oakMilkdown.init(\(MilkdownComposerView.jsString(seedMarkdown)),true);"
            webView.evaluateJavaScript(js)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "markdown":
                let empty = (body["empty"] as? Bool) ?? true
                if parent.isEmpty != empty { parent.isEmpty = empty }
                if let n = body["count"] as? NSNumber, parent.charCount != n.intValue {
                    parent.charCount = n.intValue
                }
            case "height":
                if let n = body["value"] as? NSNumber {
                    let clamped = min(max(CGFloat(n.doubleValue) + 16, parent.minHeight), parent.maxHeight)
                    if abs(clamped - parent.height) > 0.5 { parent.height = clamped }
                }
            case "submit":
                parent.onSubmit()
            default:
                break
            }
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
          #editor{height:100%;overflow:hidden;}
          /* Strip Crepe's frame card (the SwiftUI card already provides it). */
          .milkdown{background:transparent;box-shadow:none;border:none;}
          .milkdown .ProseMirror{padding:2px 2px 0;font-size:14px;line-height:1.5;}
          .milkdown .ProseMirror p{margin:0 0 4px;}
        </style>
        </head><body><div id="editor"></div>
        <script>\(js)</script>
        </body></html>
        """
    }()
}
