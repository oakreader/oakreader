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
        // 1) let the editor mount, snapshot it
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.snapshot(webView, to: "milkdown-editor.png") {
                // 2) open the Notion-style slash menu
                webView.evaluateJavaScript("window.oak && window.oak.openSlash()") { _, _ in
                    print("[Swift→JS] openSlash dispatched")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.snapshot(webView, to: "milkdown-slash.png") {
                            // 3) run an AI action, then snapshot the diff review
                            webView.evaluateJavaScript("window.oak && window.oak.improve()") { _, _ in
                                print("[Swift→JS] oak.improve() dispatched")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                    self.snapshot(webView, to: "milkdown-diff.png")
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
        let ucc = config.userContentController
        for name in ["ready", "status", "markdown", "log"] {
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
        let btn = NSButton(title: "Swift → JS: 触发 AI 校对", target: self, action: #selector(triggerProofread))
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
