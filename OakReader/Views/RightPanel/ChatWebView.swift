import AppKit
import Observation
import OakAgent
import SwiftUI
import WebKit

/// React/Tailwind chat panel hosted in a WKWebView.
///
/// The panel is a single self-contained `index.html` built by `web/chat`
/// (Vite + `vite-plugin-singlefile`), loaded from the app bundle — no local
/// server, no CORS, no relative-asset resolution.
///
/// **Why mirror `turns` instead of forwarding `SessionEvent`s.**
/// `ChatViewModel` already coalesces provider deltas into `turns` at roughly
/// 30 Hz (see `commitPendingText`), so `turns` *is* the correctly-throttled
/// stream. Re-emitting raw events would hand the WebView a firehose the Swift
/// UI never has to deal with, and would mean threading new emissions through
/// a 1,100-line event loop. Pushing the serialized snapshot on change keeps
/// one source of truth; the JS side reconciles by stable row id, so only the
/// text that actually changed re-renders.
struct ChatWebView: NSViewRepresentable {
    let viewModel: ChatViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: Coordinator.handlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // The page paints its own themed background; a transparent WebView
        // would show the window material through it and wash the text out.
        webView.setValue(false, forKey: "drawsBackground")
        // No rubber-banding: the panel is a pane inside a native window.
        webView.enclosingScrollView?.verticalScrollElasticity = .none
        context.coordinator.webView = webView

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Chat.bundle") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            Log.error(Log.ui, "Chat.bundle/index.html missing — build web/chat")
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.syncAppearance()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.handlerName)
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let handlerName = "oakChat"

        private let viewModel: ChatViewModel
        weak var webView: WKWebView?
        private var ready = false
        private var observing = false
        private var lastPayload: String?

        init(viewModel: ChatViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        func stop() { observing = false }

        // MARK: JS -> Swift

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                syncAppearance()
                startObserving()
            case "send":
                guard let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return }
                viewModel.inputText = text
                viewModel.send()
            case "abort":
                viewModel.stopStreaming()
            case "approveTool":
                if body["approved"] as? Bool == true { viewModel.approveToolCall() }
                else { viewModel.denyToolCall() }
            case "log":
                let level = body["level"] as? String ?? "warn"
                let text = body["message"] as? String ?? ""
                if level == "error" { Log.error(Log.ui, "chat webview: \(text)") }
                else { Log.debug(Log.ui, "chat webview: \(text)") }
            default:
                break
            }
        }

        // MARK: Swift -> JS

        /// Re-arm on every change. `withObservationTracking` fires once per
        /// mutation, so the callback re-registers itself to keep following
        /// `turns` for the life of the panel.
        private func startObserving() {
            guard !observing else { return }
            observing = true
            track()
        }

        private func track() {
            guard observing else { return }
            withObservationTracking {
                _ = viewModel.turns
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.observing else { return }
                    self.push()
                    self.track()
                }
            }
            push()
        }

        private func push() {
            guard ready, let webView else { return }
            let payload = Self.serialize(viewModel.turns)
            // Identical snapshots happen whenever an unrelated @Observable
            // property changes; skip the round-trip.
            guard payload != lastPayload else { return }
            lastPayload = payload
            webView.evaluateJavaScript("window.oakChat?.receive({type:'reset',turns:\(payload)})")
        }

        func syncAppearance() {
            guard let webView else { return }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            webView.evaluateJavaScript(
                "window.oakChat?.receive({type:'appearance',theme:'\(isDark ? "dark" : "light")'})"
            )
        }

        private static func serialize(_ turns: [Turn]) -> String {
            let payload: [[String: Any]] = turns.map { turn in
                var dict: [String: Any] = [
                    "id": turn.id.uuidString,
                    "role": turn.role == .user ? "user" : "assistant",
                    "text": turn.content,
                ]
                if let thinking = turn.thinking, !thinking.isEmpty { dict["thinking"] = thinking }
                if turn.error != nil { dict["isError"] = true }
                if !turn.toolUses.isEmpty {
                    dict["tools"] = turn.toolUses.map { use -> [String: Any] in
                        var tool: [String: Any] = ["id": use.id, "name": use.name, "isError": use.isError]
                        if let result = use.result { tool["result"] = result }
                        if let argsData = try? JSONEncoder().encode(use.input),
                           let argsJSON = try? JSONSerialization.jsonObject(with: argsData),
                           let pretty = try? JSONSerialization.data(
                               withJSONObject: argsJSON, options: [.prettyPrinted, .sortedKeys]),
                           let text = String(data: pretty, encoding: .utf8), text != "{}" {
                            tool["args"] = text
                        }
                        // The JS side derives phase from isError; pending needs
                        // to survive the trip so the approve/deny row renders.
                        tool["phase"] = use.status == .pending ? "pending" : nil
                        return tool.compactMapValues { $0 }
                    }
                }
                return dict
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return "[]" }
            return json
        }
    }
}
