import SwiftUI
import WebKit

/// Renders (and optionally edits) a Studio mind-map artifact with Mind Elixir in
/// a self-contained WKWebView. The `oak-mindmap` bundle + its CSS from
/// `Preview.bundle` are inlined into a tiny HTML host; the outline is pushed in
/// after load via `window.oakMindmap`.
///
/// - `editable` off: a read-only map; `outline` changes are pushed live via
///   `oakMindmap.update(...)` so a streaming generation fills in card-by-card.
/// - `editable` on: Mind Elixir's interactive editor; every edit posts the new
///   outline back through `onOutlineChanged` (the full-screen editor persists it).
struct StudioWebView: NSViewRepresentable {
    let outline: String
    var editable: Bool = false
    var onOutlineChanged: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "oakMindmap")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif

        let coord = context.coordinator
        coord.webView = webView
        coord.editable = editable
        coord.pendingOutline = outline
        coord.lastOutline = outline
        coord.onOutlineChanged = onOutlineChanged
        webView.navigationDelegate = coord
        webView.loadHTMLString(Self.html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.onOutlineChanged = onOutlineChanged
        guard coord.didFinish else {
            coord.pendingOutline = outline
            return
        }
        // Push streaming updates only for read-only maps; never clobber an
        // in-progress edit in the editable editor.
        if !editable, coord.lastOutline != outline {
            coord.lastOutline = outline
            webView.evaluateJavaScript("window.oakMindmap&&window.oakMindmap.update(\(Self.jsString(outline)));")
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onOutlineChanged: ((String) -> Void)?
        var editable = false
        var pendingOutline = ""
        var lastOutline: String?
        var didFinish = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinish = true
            let js = "window.oakMindmap&&window.oakMindmap.render(\(StudioWebView.jsString(pendingOutline)),\(editable ? "true" : "false"));"
            webView.evaluateJavaScript(js)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "oakMindmap",
                  let body = message.body as? [String: Any],
                  let outline = body["outline"] as? String else { return }
            onOutlineChanged?(outline)
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
        let css = bundleFile("oak-mindmap.css")
        let js = bundleFile("oak-mindmap.js")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        <style>
          html,body{margin:0;padding:0;height:100%;background:#ffffff;}
          #map{width:100vw;height:100vh;}
          /* XMind-ish polish on top of the theme vars */
          .map-container me-tpc{box-shadow:0 1px 4px rgba(0,0,0,0.10);border:1px solid rgba(0,0,0,0.06);}
          .map-container me-root me-tpc{box-shadow:0 2px 8px rgba(0,0,0,0.18);border:none;font-weight:600;}
          .map-container svg path{stroke-width:2.4px;}
        </style>
        </head><body><div id="map"></div>
        <script>\(js)</script>
        </body></html>
        """
    }()
}

/// Full-window presentation of a Studio artifact that needs room — the mind map
/// opens here as an interactive, editable Mind Elixir canvas.
struct StudioFullScreenView: View {
    let artifact: StudioArtifact
    let onOutlineChanged: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: artifact.kind.systemImage)
                    .foregroundStyle(.secondary)
                Text(artifact.title.isEmpty ? artifact.kind.label : artifact.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if artifact.kind == .mindmap {
                    Text("Drag, double-click to edit")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch artifact.kind {
        case .mindmap:
            StudioWebView(outline: artifact.body, editable: true, onOutlineChanged: onOutlineChanged)
        default:
            Text("This artifact can't be displayed full-screen.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
