import SwiftUI
import WebKit

/// What a widget asks the chat to do. Only these reach native code; the runtime
/// answers anything else with an error, which is ChatGPT's `supportedClientActions`
/// allow-list in miniature.
enum GenUIAction {
    /// Post `text` as the user's next turn — ChatGPT's `issue_new_turn`, the one
    /// path from a widget back to the model.
    case send(String)
    case openURL(URL)
    case copy(String)
}

/// A model-written widget: the body of a ```genui fence, rendered by the bundled
/// runtime (`Preview.bundle/genui`) in a web view.
///
/// This is ChatGPT iOS's arrangement (`ChatGPTDIL.DILWebView`):
///   - one shared web runtime, configured by native messages, reporting its
///     height and actions back;
///   - web views reused from a pool (`shell_reuse_hit`), warmed while the fence
///     is still streaming, so a widget appears without a page load;
///   - charts and maps drawn natively over slots the runtime reserves
///     (`DILNativeChartHostRequest`);
///   - a placeholder at an estimated height (`DILEstimatedHeights`) until the
///     fence closes, so the answer does not jump when it loads.
struct GenUIWidgetView: View {
    let source: String
    let isComplete: Bool
    /// Keys the widget's state, so it survives the row being rebuilt.
    let stateKey: String
    var onAction: (GenUIAction) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = Self.estimatedHeight
    @State private var failed = false
    @State private var hosts: [Int: GenUINativeHost] = [:]

    static let estimatedHeight: CGFloat = 140

    /// A body worth giving to the runtime: JSON with a `root`. Anything else is
    /// shown as code by the caller, the way ChatGPT falls back to markdown.
    static func payload(from source: String) -> [String: Any]? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["root"] != nil else { return nil }
        return object
    }

    var body: some View {
        Group {
            if !isComplete {
                placeholder
                    .onAppear { GenUIWebViewPool.shared.prewarm() }
            } else if failed {
                Label("This widget couldn't load", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let payload = Self.payload(from: source) {
                GenUIWebView(payload: payload,
                             isDark: colorScheme == .dark,
                             stateKey: stateKey,
                             height: $height,
                             failed: $failed,
                             hosts: $hosts,
                             onAction: onAction)
                    .frame(height: height)
                    .overlay(alignment: .topLeading) { nativeLayer }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Native views over the runtime's slots, at the slots' rects. The web view
    /// lays out at one CSS pixel per point, so the rects are used as they come.
    private var nativeLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(hosts.values.sorted { $0.id < $1.id }) { host in
                GenUINativeHostView(host: host)
                    .frame(width: host.rect.width, height: host.rect.height)
                    .offset(x: host.rect.minX, y: host.rect.minY)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.primary.opacity(0.05))
            .frame(height: Self.estimatedHeight)
            .overlay(ProgressView().controlSize(.small))
    }
}

/// Widget state by message and block, kept for the session. ChatGPT persists the
/// same thing to its server (`dil/view_state`); here a rebuilt row picks up
/// where the reader left it.
@MainActor
enum GenUIStateStore {
    private static var states: [String: Any] = [:]

    static func state(for key: String) -> Any? { states[key] }
    static func save(_ state: Any, for key: String) { states[key] = state }
}

// MARK: - Web view

private struct GenUIWebView: NSViewRepresentable {
    let payload: [String: Any]
    let isDark: Bool
    let stateKey: String
    @Binding var height: CGFloat
    @Binding var failed: Bool
    @Binding var hosts: [Int: GenUINativeHost]
    var onAction: (GenUIAction) -> Void

    /// Node kinds this host draws natively. The runtime falls back to SVG for
    /// any kind not listed.
    static let nativeHosts = ["chart", "pie-chart", "map"]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> GenUIWKWebView {
        let web = GenUIWebViewPool.shared.take()
        guard let web else {
            DispatchQueue.main.async { failed = true }
            return GenUIWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        web.navigationDelegate = context.coordinator
        web.router.target = context.coordinator
        context.coordinator.web = web
        // A pooled view loaded its runtime already and will not say so again.
        if web.isAppReady { context.coordinator.configure() }
        return web
    }

    func updateNSView(_ web: GenUIWKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.isDark != isDark {
            context.coordinator.isDark = isDark
            web.evaluateJavaScript("window.oakGenUI && window.oakGenUI.setTheme('\(isDark ? "dark" : "light")')")
        }
    }

    static func dismantleNSView(_ web: GenUIWKWebView, coordinator: Coordinator) {
        GenUIWebViewPool.shared.recycle(web)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: GenUIWebView
        var isDark: Bool
        weak var web: GenUIWKWebView?

        init(_ parent: GenUIWebView) {
            self.parent = parent
            self.isDark = parent.isDark
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "app-ready":
                configure()
            case "height":
                if let value = body["height"] as? Double, value > 0 {
                    parent.height = CGFloat(value)
                }
            case "state":
                if let state = body["state"] { GenUIStateStore.save(state, for: parent.stateKey) }
            case "action":
                handleAction(body["action"] as? [String: Any])
            case "native-host":
                if let host = GenUINativeHost(message: body) { parent.hosts[host.id] = host }
            case "native-host-remove":
                if let id = body["id"] as? Int { parent.hosts[id] = nil }
            case "error":
                let text = body["message"] as? String ?? "unknown"
                Log.error(Log.ui, "genui: \(text)")
                if body["fatal"] as? Bool == true { parent.failed = true }
            default:
                break
            }
        }

        /// ChatGPT's `dil-configure-widget`: the payload, the theme, the kinds
        /// drawn natively, and any state the reader already left in it.
        func configure() {
            var config: [String: Any] = [
                "payload": parent.payload,
                "theme": isDark ? "dark" : "light",
                "nativeHosts": GenUIWebView.nativeHosts,
            ]
            if let state = GenUIStateStore.state(for: parent.stateKey) { config["state"] = state }
            guard let data = try? JSONSerialization.data(withJSONObject: config),
                  let json = String(data: data, encoding: .utf8) else {
                parent.failed = true
                return
            }
            web?.evaluateJavaScript("window.oakGenUI.configure(\(json))")
        }

        private func handleAction(_ action: [String: Any]?) {
            guard let action, let type = action["type"] as? String else { return }
            switch type {
            case "send":
                if let text = action["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parent.onAction(.send(text))
                }
            case "open_url":
                if let raw = action["url"] as? String, let url = URL(string: raw),
                   ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    parent.onAction(.openURL(url))
                }
            case "copy":
                if let text = action["text"] as? String { parent.onAction(.copy(text)) }
            default:
                break
            }
        }

        /// The widget never navigates: the runtime page loads once, and a link
        /// inside it goes through `open_url` like everything else.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let isRuntime = navigationAction.request.url?.isFileURL == true
                && navigationAction.navigationType == .other
            decisionHandler(isRuntime ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            (webView as? GenUIWKWebView)?.isDead = true
            parent.failed = true
        }
    }
}

/// Hands vertical scrolling to the chat. The widget sizes itself to its content,
/// so it never scrolls; without this the thread stops scrolling whenever the
/// pointer is over a widget.
final class GenUIWKWebView: WKWebView {
    let router = GenUIMessageRouter()
    /// The runtime has loaded and announced itself (`app-ready`).
    var isAppReady = false
    /// Its content process died: never hand it out again.
    var isDead = false

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Delivers a web view's messages to whichever widget holds it now. Weak, so the
/// content controller does not keep a coordinator — and through it a view —
/// alive after the web view has gone back to the pool.
final class GenUIMessageRouter: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["type"] as? String == "app-ready" {
            (message.webView as? GenUIWKWebView)?.isAppReady = true
        }
        target?.userContentController(controller, didReceive: message)
    }
}

/// Web views with the runtime already loaded. ChatGPT iOS keeps its DIL shells
/// the same way: loading the page is most of a widget's start-up cost, and a
/// conversation shows many widgets over its life but few at once.
@MainActor
final class GenUIWebViewPool {
    static let shared = GenUIWebViewPool()

    private var idle: [GenUIWKWebView] = []
    private let maxIdle = 3
    private let runtimeDirectory = Bundle.main.resourceURL?.appendingPathComponent("Preview.bundle/genui")

    /// Start one loading, so the next widget finds it ready.
    func prewarm() {
        guard idle.isEmpty, let web = make() else { return }
        idle.append(web)
    }

    func take() -> GenUIWKWebView? {
        while let web = idle.popLast() {
            if !web.isDead { return web }
        }
        return make()
    }

    func recycle(_ web: GenUIWKWebView) {
        web.router.target = nil
        web.navigationDelegate = nil
        web.removeFromSuperview()
        guard !web.isDead, idle.count < maxIdle else { return }
        web.evaluateJavaScript("window.oakGenUI && window.oakGenUI.reset()")
        idle.append(web)
    }

    private func make() -> GenUIWKWebView? {
        guard let dir = runtimeDirectory else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = GenUIWKWebView(frame: .zero, configuration: config)
        config.userContentController.add(web.router, name: "oakGenUI")
        web.setValue(false, forKey: "drawsBackground")
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        return web
    }
}
