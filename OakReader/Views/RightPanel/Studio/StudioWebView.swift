import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Imperative handle the full-screen toolbar uses to drive the mind-map web view
/// (fit / layout / export). `StudioWebView` wires its `WKWebView` in here.
@MainActor
final class MindmapController: ObservableObject {
    weak var webView: WKWebView?

    func fit() { eval("window.oakMindmap&&window.oakMindmap.fit()") }
    func setLayout(_ dir: String) { eval("window.oakMindmap&&window.oakMindmap.setLayout('\(dir)')") }
    func exportImage(_ format: String) { eval("window.oakMindmap&&window.oakMindmap.exportImage('\(format)')") }
    func addChild() { eval("window.oakMindmap&&window.oakMindmap.addChildToSelected()") }
    func openNote() { eval("window.oakMindmap&&window.oakMindmap.openNote()") }

    /// Let the user pick an image file and attach it to the selected node. The JS
    /// side downscales/recompresses before storing it in the map body.
    func pickAndAddImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .bmp, .tiff, .webP, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            let mime = StudioWebView.mimeType(for: url)
            let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
            self?.eval("window.oakMindmap&&window.oakMindmap.addImageToSelected(\(StudioWebView.jsString(dataURL)))")
        }
    }

    private func eval(_ js: String) { webView?.evaluateJavaScript(js) }
}

/// Renders (and optionally edits) a Studio mind-map artifact with Mind Elixir in
/// a self-contained WKWebView. The `oak-mindmap` bundle + CSS from `Preview.bundle`
/// are inlined into a tiny HTML host; the outline is pushed in after load.
///
/// - `editable` off: read-only; `outline` changes are pushed live via
///   `oakMindmap.update(...)` so a streaming generation fills in card-by-card.
/// - `editable` on: Mind Elixir's interactive editor + native toolbar; edits post
///   the new JSON body back through `onBodyChanged`.
struct StudioWebView: NSViewRepresentable {
    /// The artifact body: a streamed bullet outline, or a Mind Elixir JSON object
    /// once the map has been hand-edited. The JS side auto-detects which.
    let outline: String
    var editable: Bool = false
    var controller: MindmapController? = nil
    /// Invoked when an edit changes the map; the payload is the new body (JSON).
    var onBodyChanged: ((String) -> Void)? = nil
    /// Read-only: invoked with a node's source anchor (a verbatim document quote)
    /// when the node is clicked, so the host can jump to it in the document.
    var onNodeClick: ((String) -> Void)? = nil

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
        coord.lastEditable = editable
        coord.pendingOutline = outline
        coord.lastOutline = outline
        coord.onBodyChanged = onBodyChanged
        coord.onNodeClick = onNodeClick
        webView.navigationDelegate = coord
        controller?.webView = webView
        webView.loadHTMLString(Self.html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.onBodyChanged = onBodyChanged
        coord.onNodeClick = onNodeClick
        coord.editable = editable
        controller?.webView = webView
        guard coord.didFinish else {
            coord.pendingOutline = outline
            return
        }
        // Flip read-only ↔ editable in place (inline "edit" toggle), preserving
        // the current map. Done before any content push.
        if coord.lastEditable != editable {
            coord.lastEditable = editable
            coord.lastOutline = outline
            webView.evaluateJavaScript("window.oakMindmap&&window.oakMindmap.setEditable(\(editable ? "true" : "false"));")
        } else if !editable, coord.lastOutline != outline {
            // Live-stream new outline content into the read-only map. Never feed a
            // JSON body to update() — that path parses outlines only.
            coord.lastOutline = outline
            if !outline.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                webView.evaluateJavaScript("window.oakMindmap&&window.oakMindmap.update(\(Self.jsString(outline)));")
            }
        }
        // Re-skin if the app's light/dark appearance flipped while open.
        let dark = Self.isDark(webView)
        if coord.lastDark != dark {
            coord.lastDark = dark
            webView.evaluateJavaScript(Self.appearanceJS(dark)
                + "window.oakMindmap&&window.oakMindmap.applyTheme&&window.oakMindmap.applyTheme();")
        }
    }

    /// True when the web view should render in dark appearance.
    static func isDark(_ webView: WKWebView) -> Bool {
        webView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// JS that toggles the `oak-dark` / `oak-light` body classes the CSS keys off.
    static func appearanceJS(_ dark: Bool) -> String {
        "document.body.classList.toggle('oak-dark',\(dark));document.body.classList.toggle('oak-light',\(!dark));"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onBodyChanged: ((String) -> Void)?
        var onNodeClick: ((String) -> Void)?
        var editable = false
        var lastEditable = false
        var pendingOutline = ""
        var lastOutline: String?
        var lastDark: Bool?
        var didFinish = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinish = true
            let dark = StudioWebView.isDark(webView)
            lastDark = dark
            let js = StudioWebView.appearanceJS(dark)
                + "window.oakMindmap&&window.oakMindmap.render(\(StudioWebView.jsString(pendingOutline)),\(editable ? "true" : "false"));"
            webView.evaluateJavaScript(js)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "oakMindmap", let body = message.body as? [String: Any] else { return }
            if let action = body["action"] as? String, action == "export",
               let format = body["format"] as? String, let dataURL = body["dataURL"] as? String {
                StudioWebView.saveExport(dataURL: dataURL, format: format)
                return
            }
            if let action = body["action"] as? String, action == "nodeClick",
               let anchor = body["anchor"] as? String {
                onNodeClick?(anchor)
                return
            }
            // An edit round-tripped back: the new body is JSON (`data`); the
            // legacy outline key is still accepted for safety.
            if let updated = (body["data"] as? String) ?? (body["outline"] as? String) {
                onBodyChanged?(updated)
            }
        }
    }

    // MARK: - Export

    /// Decode a `data:` URL from the JS export and write it via a Save dialog.
    @MainActor
    static func saveExport(dataURL: String, format: String) {
        guard let comma = dataURL.range(of: ","),
              let data = Data(base64Encoded: String(dataURL[comma.upperBound...]))
        else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mindmap.\(format)"
        panel.allowedContentTypes = [format == "svg" ? .svg : .png]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - HTML host

    /// Encode a Swift string as a JS string literal (quoted, escaped).
    static func jsString(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// A best-effort MIME type for a picked image file, for the `data:` URL.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
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
          :root{
            --oak-canvas:#FBFBFA; --oak-anchor:#C77A2E;
            --oak-spine-size:14px; --oak-spine-weight:560;
            --oak-leaf-size:12px;  --oak-leaf-weight:450;
            --oak-root-size:16px;  --oak-root-weight:640;
          }
          html,body{margin:0;padding:0;height:100%;background:var(--oak-canvas);
            -webkit-font-smoothing:antialiased;
            font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;}
          #map{width:100vw;height:100vh;}

          /* Branch chips: quiet paper, hairline, soft elevation. */
          .map-container me-tpc{
            font-size:var(--oak-spine-size); font-weight:var(--oak-spine-weight);
            letter-spacing:-0.005em; line-height:1.3;
            box-shadow:0 1px 2px rgba(0,0,0,0.05),0 1px 5px rgba(0,0,0,0.04);
            transition:box-shadow .14s ease, transform .14s ease;
          }
          .map-container me-tpc:hover{
            box-shadow:0 2px 5px rgba(0,0,0,0.08),0 3px 12px rgba(0,0,0,0.07);
          }

          /* Leaves (no children): plain greyed text hanging off the limb. */
          .map-container me-tpc.oak-leaf{
            font-size:var(--oak-leaf-size); font-weight:var(--oak-leaf-weight);
            box-shadow:none; background:transparent; border-color:transparent;
          }

          /* Root: the single heavy anchor. */
          .map-container me-root me-tpc{
            font-size:var(--oak-root-size)!important; font-weight:var(--oak-root-weight);
            letter-spacing:-0.01em; padding:9px 18px!important;
            box-shadow:0 3px 8px rgba(0,0,0,0.18),0 1px 3px rgba(0,0,0,0.12);
            border:none!important;
          }

          /* Edges: tapered, rounded caps; branch color carries identity. */
          .map-container svg path{
            stroke-width:2.2px; stroke-linecap:round; stroke-linejoin:round; opacity:0.95;
          }

          /* Anchored leaf: jump-to-source affordance (class added by JS). */
          .map-container me-tpc.oak-anchored{
            cursor:pointer;
            border-bottom:1.5px dotted color-mix(in srgb,var(--oak-anchor) 55%,transparent);
          }
          .map-container me-tpc.oak-anchored::after{
            content:""; display:inline-block; width:5px; height:5px; margin-left:6px;
            border-radius:50%; background:var(--oak-anchor);
            vertical-align:middle; opacity:0.7;
            transition:transform .14s ease, opacity .14s ease;
          }
          .map-container me-tpc.oak-anchored:hover{
            border-bottom-color:var(--oak-anchor);
            box-shadow:0 0 0 2px color-mix(in srgb,var(--oak-anchor) 28%,transparent),0 2px 8px rgba(0,0,0,0.08);
          }
          .map-container me-tpc.oak-anchored:hover::after{ transform:scale(1.25); opacity:1; }

          /* Noted node: a small comment dot in the corner (class added by JS). */
          .map-container me-tpc.oak-noted{ position:relative; }
          .map-container me-tpc.oak-noted::before{
            content:""; position:absolute; top:-3px; right:-3px;
            width:7px; height:7px; border-radius:50%;
            background:#E0A45C; box-shadow:0 0 0 2px var(--oak-canvas);
          }

          /* Node images sit above the label; keep them tidy. */
          .map-container me-tpc img{
            display:block; max-width:240px; border-radius:6px; margin:2px auto;
          }

          /* KaTeX inside a node should inherit the node's ink + size. */
          .map-container me-tpc .katex{ font-size:1em; color:inherit; }

          /* Comment popover — a small floating editor anchored near a node. */
          #oak-note{
            position:fixed; z-index:9999; width:248px;
            background:#FFFFFF; border:1px solid rgba(0,0,0,0.12); border-radius:10px;
            box-shadow:0 6px 24px rgba(0,0,0,0.16),0 2px 6px rgba(0,0,0,0.10);
            padding:8px;
          }
          #oak-note textarea{
            width:100%; min-height:84px; box-sizing:border-box; resize:vertical;
            border:none; outline:none; background:transparent; color:#26282C;
            font-family:inherit; font-size:12px; line-height:1.4;
          }
          #oak-note .oak-note-close{
            position:absolute; top:4px; right:6px; border:none; background:transparent;
            color:#9AA0A8; font-size:12px; cursor:pointer; padding:2px 4px; line-height:1;
          }
          #oak-note .oak-note-close:hover{ color:#26282C; }
          body.oak-dark #oak-note{ background:#2A2A2D; border-color:rgba(255,255,255,0.14); }
          body.oak-dark #oak-note textarea{ color:#ECECEE; }

          /* Dark: native sets <body class="oak-dark">; re-points ME node vars. */
          body.oak-dark{ --oak-canvas:#1C1C1E; --oak-anchor:#E0A45C; }
          body.oak-dark .map-container{
            --main-color:#ECECEE; --main-bgcolor:#2A2A2D;
            --main-border:1px solid rgba(255,255,255,0.10);
            --color:#9AA0A8; --bgcolor:#1C1C1E;
            --root-color:#1C1C1E; --root-bgcolor:#E8E8EA; --root-border-color:#E8E8EA;
          }
          body.oak-dark .map-container me-tpc{
            box-shadow:0 1px 2px rgba(0,0,0,0.4),0 1px 6px rgba(0,0,0,0.3);
          }
          body.oak-dark .map-container me-root me-tpc{ box-shadow:0 3px 10px rgba(0,0,0,0.55); }
        </style>
        </head><body><div id="map"></div>
        <script>\(js)</script>
        </body></html>
        """
    }()
}

/// Full-window presentation of a Studio artifact that needs room — the mind map
/// opens here as an interactive, editable Mind Elixir canvas with a toolbar.
struct StudioFullScreenView: View {
    let artifact: StudioArtifact
    let onBodyChanged: (String) -> Void
    let onClose: () -> Void
    /// Jumps to the passage a flashcard cites — `(quote, 1-based page?)`.
    var onJumpToSource: ((String, Int?) -> Void)? = nil
    /// Deletes the flashcard at the given index from the quiz deck.
    var onDeleteCard: ((Int) -> Void)? = nil

    @StateObject private var controller = MindmapController()
    @State private var layoutSide = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.kind.systemImage)
                .foregroundStyle(.secondary)
            Text(artifact.title.isEmpty ? artifact.kind.label : artifact.title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            if artifact.kind == .mindmap {
                toolbar
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
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolButton("plus", "Add child node") { controller.addChild() }
            toolButton("text.bubble", "Add a comment to the selected node") { controller.openNote() }
            toolButton("photo", "Add an image to the selected node") { controller.pickAndAddImage() }
            Divider().frame(height: 16)
            toolButton("arrow.up.left.and.down.right.magnifyingglass", "Fit to view") {
                controller.fit()
            }
            toolButton(layoutSide ? "arrow.left.and.right" : "arrow.right", layoutSide ? "Split layout" : "Right layout") {
                layoutSide.toggle()
                controller.setLayout(layoutSide ? "side" : "right")
            }
            Menu {
                Button("PNG image") { controller.exportImage("png") }
                Button("SVG vector") { controller.exportImage("svg") }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export")
        }
        .font(.system(size: 13))
    }

    private func toolButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var content: some View {
        switch artifact.kind {
        case .mindmap:
            StudioWebView(
                outline: artifact.body,
                editable: true,
                controller: controller,
                onBodyChanged: onBodyChanged
            )
        case .quiz:
            if let deck = artifact.quizDeck {
                InlineDeckView(deck: deck, onDeleteCard: onDeleteCard, onJumpToSource: onJumpToSource, embeddedInSheet: true)
                    .frame(maxWidth: 1040, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailableFullScreen
            }
        default:
            unavailableFullScreen
        }
    }

    private var unavailableFullScreen: some View {
        Text("This artifact can't be displayed full-screen.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
