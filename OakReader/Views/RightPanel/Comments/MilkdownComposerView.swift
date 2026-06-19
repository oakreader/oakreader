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

    /// Insert a memo reference (link) at the caret, consuming a typed `@` trigger.
    func insertReference(label: String, href: String) {
        eval("window.oakMilkdown&&window.oakMilkdown.insertReference(\(MilkdownComposerView.jsString(label)),\(MilkdownComposerView.jsString(href)))")
    }

    /// Open the `@` memo picker from the toolbar button (reports the caret coords).
    func requestMention() { eval("window.oakMilkdown&&window.oakMilkdown.requestMention()") }

    func getMarkdown(_ completion: @escaping (String) -> Void) {
        guard let webView else { completion(""); return }
        webView.evaluateJavaScript("window.oakMilkdown?window.oakMilkdown.getMarkdown():''") { result, _ in
            completion((result as? String) ?? "")
        }
    }

    private func eval(_ js: String) { webView?.evaluateJavaScript(js) }
}

/// Retains a single, already-booted composer `WKWebView` for a document's
/// lifetime. The right panel is `switch`-rendered, so re-entering the Notes tab
/// rebuilds `CommentsPanelView` (and its composer) from scratch — and a fresh
/// `WKWebView` reloads the whole Milkdown bundle + re-boots Crepe behind an
/// opacity fade, which reads as a "flick" before "Jot a thought…" appears. Held on
/// `CommentsViewModel`, this lets `MilkdownComposerView` rebind the live editor
/// instead of reloading it. Only the persistent *create* composer reuses one;
/// inline card edits stay one-shot.
final class ComposerWebHolder {
    /// Strong: SwiftUI releases the representable's `NSView` when the Notes tab is
    /// switched away, so the holder is the only thing keeping the editor alive
    /// between visits. Released when the document (and its `CommentsViewModel`) goes.
    /// Only ever touched on the main actor (NSViewRepresentable callbacks).
    var webView: WKWebView?
}

/// The WYSIWYG Markdown editing surface — Milkdown Crepe in a `WKWebView`, with
/// the `oak-milkdown` bundle + CSS from `Preview.bundle` inlined into a tiny HTML
/// host. Seeds `initialMarkdown` after load; reports content height (for native
/// auto-grow), emptiness + char count, and ⌘↩ submit back through the
/// `oakMilkdown` message handler. Modeled on the (removed) MilkdownEditorView and
/// the concept-map / cite-anchor `Preview.bundle` hosts.
struct MilkdownComposerView: NSViewRepresentable {
    let initialMarkdown: String
    let controller: MilkdownComposerController
    @Binding var isEmpty: Bool
    @Binding var charCount: Int
    @Binding var height: CGFloat
    /// Names of the formatting commands (`bold`/`italic`/`code`/`heading`/
    /// `bulletList`/`orderedList`) currently active at the caret, reported by the
    /// editor on every selection change so the toolbar can highlight them — making
    /// it obvious the same button toggles the style back off.
    @Binding var activeFormats: Set<String>
    var minHeight: CGFloat = 44
    var maxHeight: CGFloat = 220
    /// When set, reuse this document's already-booted editor across Notes-tab
    /// visits instead of reloading a fresh one (kills the boot+fade "flick"). Only
    /// the persistent create composer passes one; inline edits leave it nil.
    var reuseHolder: ComposerWebHolder? = nil
    var onSubmit: () -> Void = {}
    /// The user typed `@` (or hit the button) — open the memo-reference picker,
    /// anchored at the given caret point in the editor's coordinate space (nil if
    /// coords were unavailable).
    var onMention: (CGPoint?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.seedMarkdown = initialMarkdown

        // Reuse the document's already-booted editor (the create composer) so
        // re-entering the Notes tab rebinds the live WKWebView instead of reloading
        // the whole Milkdown bundle + re-booting Crepe behind the opacity fade —
        // which was the visible "flick" before "Jot a thought…" appeared. The page
        // is already loaded (didFinish won't fire again), so we rebind the message
        // handler / delegate and `resync()` the native state to the live content.
        if let cached = reuseHolder?.webView {
            let ucc = cached.configuration.userContentController
            ucc.removeScriptMessageHandler(forName: "oakMilkdown")
            ucc.add(context.coordinator, name: "oakMilkdown")
            cached.navigationDelegate = context.coordinator
            controller.webView = cached
            cached.evaluateJavaScript("window.oakMilkdown&&window.oakMilkdown.resync()")
            return cached
        }

        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "oakMilkdown")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")   // blend into the card
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(Self.html, baseURL: nil)
        controller.webView = webView
        reuseHolder?.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Break the WKWebView → userContentController → Coordinator → parent →
        // reuseHolder → WKWebView retain cycle when the view is torn down (tab
        // switch / document close). `add(handler:name:)` retains the Coordinator
        // strongly, and the reused-editor path routes back to the webview through
        // the holder — so without this the WKWebView (and its web content process)
        // would leak. A reused editor survives via the document's ComposerWebHolder
        // alone; makeNSView re-adds this handler on the next Notes visit.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "oakMilkdown")
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
            case "format":
                let keys = ["bold", "italic", "code", "heading", "bulletList", "orderedList"]
                let set = Set(keys.filter { (body[$0] as? Bool) == true })
                if parent.activeFormats != set { parent.activeFormats = set }
            case "submit":
                parent.onSubmit()
            case "mention":
                if let left = body["left"] as? NSNumber, let bottom = body["bottom"] as? NSNumber {
                    parent.onMention(CGPoint(x: left.doubleValue, y: bottom.doubleValue))
                } else {
                    parent.onMention(nil)
                }
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

    /// The app accent as a CSS hex, so the in-editor `#tag` color tracks
    /// `Color.accentColor` (matching the card's `NoteTagChip`).
    private static var accentHex: String {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    private static let html: String = {
        let css = bundleFile("oak-milkdown.css")
        let js = bundleFile("oak-milkdown.js")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        <style>
          /* Content-driven height: the page grows to its content and the native
             frame follows (see reportHeight). Pinning #editor to height:100%
             would tie the measured height to the frame, ratcheting it up and
             pinning the layout (first line jumps on a newline). */
          html,body{margin:0;padding:0;background:transparent;}
          /* Match native text weight. WKWebView defaults to subpixel font
             smoothing, which renders noticeably HEAVIER than the rest of the app
             (SwiftUI/AppKit use grayscale antialiasing) — so the editor text read
             bolder than the saved note cards. Force grayscale so they match. */
          html{-webkit-font-smoothing:antialiased;}
          /* The native frame auto-grows to fit content, so the document never
             needs its own scrollbar. But in the ~1-frame window where the web
             content has reflowed taller and the native frame hasn't caught up,
             the document briefly overflows and WebKit flashes a scroller —
             appear-then-disappear on every new line. Hide the scrollbar chrome
             so the line just slides in. Scrolling still works for the rare
             >maxHeight note (ProseMirror keeps the caret in view); only the bar
             is hidden. */
          /* Page itself NEVER scrolls. Across the ~1-frame JS→native height bridge
             the content is briefly taller than the (not-yet-grown) native frame;
             if the PAGE could scroll, ProseMirror would scroll it to chase the
             caret, yanking the first line up and back (the residual micro-jump).
             With the page locked, that transient simply reveals the new line a
             frame late at the bottom — imperceptible — and the first line stays put. */
          html,body{scrollbar-width:none;overflow:hidden;}
          ::-webkit-scrollbar{width:0;height:0;display:none;}
          /* Fade in after the first paint so the editor doesn't flash/resize
             visibly when the Notes tab appears. */
          body{opacity:0;transition:opacity .12s ease-out;}
          body.ready{opacity:1;}
          /* The editor — not the page — is the scroll container, and it only
             actually scrolls once content exceeds the native max frame (220).
             Below that it grows to fit (no overflow → no scroll → no jump);
             above it, this scrolls so a long note's caret stays visible. */
          #editor{max-height:220px;overflow-y:auto;overflow-x:hidden;}
          /* Strip Crepe's frame card (the SwiftUI card already provides it). */
          .milkdown{background:transparent;box-shadow:none;border:none;}
          /* Right padding gives the end-of-line caret room — at 2px the insertion
             caret sat flush against (and clipped into) the last typed character. */
          /* 13px matches the saved card body (StreamingMarkdownView .oak(fontSize: 13)
             in CommentsPanelView), so typing is a true WYSIWYG of the card — no
             size jump on send. */
          .milkdown .ProseMirror{padding:2px 10px 0 2px;font-size:13px;line-height:1.5;}
          .milkdown .ProseMirror p{margin:0 0 4px;}
          /* Inline #tag highlight (flomo-style) — accent text, no box, so it reads
             as a tag while staying natural to edit. Matches the card's tag chip. */
          .milkdown .ProseMirror .oak-tag{color:\(accentHex);font-weight:500;}
        </style>
        </head><body><div id="editor"></div>
        <script>\(js)</script>
        </body></html>
        """
    }()
}
