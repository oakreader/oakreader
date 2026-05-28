// Standalone WKWebView host for the Milkdown AI-proofread POC.
// Run with:  swift host.swift
// Mirrors OakReader's existing bridge pattern (NotePreviewView.swift):
//   JS -> Swift via userContentController.add(name:)
//   Swift -> JS via evaluateJavaScript
import AppKit
import WebKit

setbuf(stdout, nil) // unbuffered so prints flush immediately

let distIndex = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("dist/index.html")

// Optional CLI arg: load an http(s) URL instead of the local file bundle.
// Only treat http(s) args as the override; flags like --no-demo are ignored here.
let overrideURL: URL? = CommandLine.arguments
    .dropFirst()
    .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    .flatMap(URL.init(string:))

final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        // This is the JS -> Swift direction. In the real app these would drive
        // NotesViewModel (e.g. persist markdown, update status chip).
        switch message.name {
        case "ready":   print("[JS→Swift] ready:", message.body)
        case "status":  print("[JS→Swift] status:", message.body)
        case "markdown":
            let md = (message.body as? String) ?? ""
            print("[JS→Swift] markdown updated (\(md.count) chars):\n----\n\(md)\n----")
        case "aiRequest":
            // Mock AI: stream a revised version so the diff review renders.
            guard let dict = message.body as? [String: Any], let id = dict["id"] as? Int,
                  let webView = probeWebView else { return }
            let selection = (dict["selection"] as? String) ?? ""
            let revised = selection.isEmpty
                ? "A revised sentence."
                : selection
                    .replacingOccurrences(of: "look ported onto Crepe", with: "aesthetic, ported onto Crepe")
                    .replacingOccurrences(of: "Body text is", with: "The body is set in")
                    .replacingOccurrences(of: "640px column", with: "narrow 640px column")
            func push(_ s: String) {
                let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
                let lit = String(decoding: d, as: UTF8.self).dropFirst().dropLast()
                webView.evaluateJavaScript("window.oakEditor.__aiChunk(\(id), \(lit))", completionHandler: nil)
            }
            // Stream in a few chunks, then finish.
            let chunks = stride(from: 0, to: revised.count, by: 12).map { i -> String in
                let start = revised.index(revised.startIndex, offsetBy: i)
                let end = revised.index(start, offsetBy: 12, limitedBy: revised.endIndex) ?? revised.endIndex
                return String(revised[start..<end])
            }
            for (i, ch) in chunks.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(i)) { push(ch) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(chunks.count) + 0.1) {
                webView.evaluateJavaScript("window.oakEditor.__aiDone(\(id))", completionHandler: nil)
            }
        default:        print("[JS→Swift] \(message.name):", message.body)
        }
    }

    weak var probeWebView: WKWebView?
    private var didOrchestrate = false

    func snapshot(_ webView: WKWebView, to name: String, then: (() -> Void)? = nil) {
        let cfg = WKSnapshotConfiguration()
        webView.takeSnapshot(with: cfg) { image, err in
            if let image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: "/tmp/\(name)")
                try? png.write(to: url)
                print("[snapshot] wrote /tmp/\(name)")
            } else {
                print("[snapshot] failed:", err as Any)
            }
            then?()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[host] page loaded")
        if CommandLine.arguments.contains("--no-demo") { return }
        guard !didOrchestrate else { return }
        didOrchestrate = true
        // 0) push sample markdown so the type typography is visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let sample = """
            # The Quiet Type

            This is *type.baby*'s look ported onto Crepe. Body text is **PT Serif**, set in a 640px column with a 1.4 line-height.

            ## Why serif

            A book-like serif invites slower reading. Links carry a [subtle underline](https://type.baby), and inline `code` stays a quiet red.

            > Restraint is a feature. The page should disappear.

            - First thought
            - Second thought
            - A [[Page 3]] reference and a #tag
            """
            let data = (try? JSONSerialization.data(withJSONObject: [sample])) ?? Data("[\"\"]".utf8)
            let literal = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
            let js = "window.oakEditor && window.oakEditor.setMarkdown(\(literal))"
            webView.evaluateJavaScript(js) { _, _ in print("[Swift→JS] pushed sample") }
        }
        // 0b) programmatically select a paragraph → should post textSelected
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let selJS = """
            (function(){
              var p = document.querySelector('#editor .ProseMirror p');
              if(!p) return 'no-p';
              var r = document.createRange(); r.selectNodeContents(p);
              var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
              document.dispatchEvent(new Event('selectionchange'));
              return 'selected';
            })()
            """
            webView.evaluateJavaScript(selJS) { res, _ in print("[Swift→JS] select →", res ?? "nil") }
        }
        // 1) let the editor mount, snapshot it
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            self.snapshot(webView, to: "milkdown-editor.png") {
                // 2) open the slash menu, snapshot it
                webView.evaluateJavaScript("window.oakEditor && window.oakEditor.__openSlash()") { _, _ in
                    print("[Swift→JS] __openSlash dispatched")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.snapshot(webView, to: "milkdown-slash.png") {
                            // 3) re-select a paragraph and run AI → mock responder
                            //    streams a revision, then snapshot the diff review.
                            let sel = "(function(){var p=document.querySelector('#editor .ProseMirror p');if(!p)return;var r=document.createRange();r.selectNodeContents(p);var s=window.getSelection();s.removeAllRanges();s.addRange(r);})()"
                            webView.evaluateJavaScript(sel) { _, _ in
                                webView.evaluateJavaScript("window.oakEditor && window.oakEditor.runAI('Improve writing')") { _, _ in
                                    print("[Swift→JS] runAI dispatched")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                        self.snapshot(webView, to: "milkdown-diff.png")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[host] nav failed:", error)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    let bridge = Bridge()

    // A standalone Swift app has no menu bar, so the standard Cmd+X/C/V/A/Z
    // key equivalents (which live on the Edit menu and dispatch to the first
    // responder) never fire. Build a minimal App + Edit menu to wire them up.
    func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        installMenu()
        let config = WKWebViewConfiguration()
        // Match MilkdownEditorView: allow ES-module loads across file:// origin.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let ucc = config.userContentController
        for name in ["ready", "status", "markdown", "log", "textSelected", "selectionCleared", "aiRequest"] {
            ucc.add(bridge, name: name)
        }

        let frame = NSRect(x: 0, y: 0, width: 820, height: 720)
        webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = bridge
        bridge.probeWebView = webView

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Milkdown AI-Proofread POC (WKWebView)"

        // Native toolbar button proves the Swift -> JS direction.
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let btn = NSButton(title: "Swift → JS: Trigger AI proofread", target: self, action: #selector(triggerProofread))
        bar.addArrangedSubview(btn)

        let stack = NSStackView(views: [bar, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: frame)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView) // give the web content focus so focus-gated UI (selection toolbar) renders

        if let overrideURL {
            print("[host] loading override URL:", overrideURL.absoluteString)
            webView.load(URLRequest(url: overrideURL))
        } else {
            guard FileManager.default.fileExists(atPath: distIndex.path) else {
                print("[host] ERROR: build first with `npm run build`. Missing:", distIndex.path)
                NSApp.terminate(nil); return
            }
            webView.loadFileURL(distIndex, allowingReadAccessTo: distIndex.deletingLastPathComponent())
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func triggerProofread() {
        webView.evaluateJavaScript("window.oak && window.oak.improve()") { _, err in
            if let err { print("[Swift→JS] error:", err) } else { print("[Swift→JS] oak.improve() dispatched") }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
