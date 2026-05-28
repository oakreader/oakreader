import SwiftUI
import WebKit
import os
import OakAI

private let log = Logger(subsystem: "com.oakreader.OakEditor", category: "editor")

/// Appearance for the editor. `.auto` follows the system light/dark setting.
public enum EditorTheme: Sendable {
    case auto, light, dark
}

/// AI assist configuration. The editor streams completions through OakAI's
/// `ProviderRouter` using these values; the host supplies them (e.g. from its
/// own preferences) and may recompute them each render.
public struct EditorAIConfig: Sendable {
    public var providerId: String
    public var model: String
    public var systemPrompt: String
    public var maxTokens: Int

    public init(providerId: String, model: String, systemPrompt: String, maxTokens: Int = 4096) {
        self.providerId = providerId
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
    }
}

/// Geometry + actions for an active text selection, handed to the host so it can
/// show its own selection UI (a native popup) anchored over the selection.
public struct EditorSelection {
    public let text: String
    /// Screen-space points at the top and bottom of the selection rect, for
    /// positioning a popup above (or, on overflow, below) the selection.
    public let topScreenPoint: NSPoint
    public let bottomScreenPoint: NSPoint
    /// Run Crepe's AI over the current selection (streams + diff-review). Pass a
    /// natural-language instruction, e.g. "Improve writing".
    public let runAI: (String) -> Void
}

/// A reusable WYSIWYG Markdown editor (Milkdown / Crepe) hosted in a WKWebView.
///
/// Markdown is the source of truth: the editor edits visually and reports clean
/// Markdown via `onChange`. The host owns persistence. The editor knows nothing
/// about notes — image storage and reference handling are injected.
///
/// Content is (re)loaded when `identity` changes (e.g. switching documents), and
/// also when `content` is replaced out-of-band (e.g. the host appends a quote),
/// but never on the keystroke echo of the user's own edits.
public struct MilkdownEditor: NSViewRepresentable {
    public var content: String
    public var identity: AnyHashable
    public var theme: EditorTheme
    public var aiConfig: EditorAIConfig?
    /// Base directory used to resolve relative image paths to file:// URLs.
    public var resourceBaseURL: URL?
    public var onChange: (String) -> Void
    /// Persist image bytes (data, file-extension) and return the path to store
    /// in the Markdown (typically relative to `resourceBaseURL`).
    public var imageUploader: ((Data, String) -> String?)?
    public var onReferenceClick: ((String) -> Void)?
    public var onTagClick: ((String) -> Void)?
    /// Fired when the user selects text; the host shows its own popup.
    public var onSelection: ((EditorSelection) -> Void)?
    /// Fired when the selection collapses or the view scrolls; host dismisses.
    public var onSelectionCleared: (() -> Void)?

    public init(
        content: String,
        identity: AnyHashable,
        theme: EditorTheme = .auto,
        aiConfig: EditorAIConfig? = nil,
        resourceBaseURL: URL? = nil,
        onChange: @escaping (String) -> Void,
        imageUploader: ((Data, String) -> String?)? = nil,
        onReferenceClick: ((String) -> Void)? = nil,
        onTagClick: ((String) -> Void)? = nil,
        onSelection: ((EditorSelection) -> Void)? = nil,
        onSelectionCleared: (() -> Void)? = nil
    ) {
        self.content = content
        self.identity = identity
        self.theme = theme
        self.aiConfig = aiConfig
        self.resourceBaseURL = resourceBaseURL
        self.onChange = onChange
        self.imageUploader = imageUploader
        self.onReferenceClick = onReferenceClick
        self.onTagClick = onTagClick
        self.onSelection = onSelection
        self.onSelectionCleared = onSelectionCleared
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        for name in ["ready", "markdown", "aiRequest", "aiCancel", "imageUpload", "refClick", "tagClick", "textSelected", "selectionCleared", "status", "log"] {
            controller.add(context.coordinator, name: name)
        }

        // Inject the resource base + initial theme before the module runs.
        let baseStr = context.coordinator.escapedBaseURL(resourceBaseURL)
        let themeStr = context.coordinator.resolvedTheme()
        let bootstrap = """
        window.__OAK_NOTES_BASE__ = "\(baseStr)";
        document.documentElement.setAttribute('data-theme', '\(themeStr)');
        """
        controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // ES-module bundle loaded from file://: allow cross-origin module loads.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        context.coordinator.webView = webView

        guard let indexURL = Bundle.module.url(
            forResource: "index", withExtension: "html", subdirectory: "Milkdown.bundle"
        ) else {
            log.error("Milkdown.bundle/index.html not found in OakEditor bundle")
            return webView
        }
        webView.loadFileURL(indexURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncContentIfNeeded()
        context.coordinator.syncThemeIfNeeded()
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MilkdownEditor
        weak var webView: WKWebView?

        private var isReady = false
        private var loadedIdentity: AnyHashable?
        private var loadedContent: String?
        private var lastEmitted: String?
        private var lastTheme: String?
        private let router = ProviderRouter()
        private var aiTasks: [Int: Task<Void, Never>] = [:]

        init(parent: MilkdownEditor) { self.parent = parent }

        // MARK: Theme

        func resolvedTheme() -> String {
            switch parent.theme {
            case .light: return "light"
            case .dark: return "dark"
            case .auto: return isDarkMode() ? "dark" : "light"
            }
        }

        private func isDarkMode() -> Bool {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        func escapedBaseURL(_ url: URL?) -> String {
            guard let url else { return "" }
            let s = url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
            return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }

        func syncThemeIfNeeded() {
            guard isReady else { return }
            let theme = resolvedTheme()
            guard theme != lastTheme else { return }
            lastTheme = theme
            eval("window.oakEditor && window.oakEditor.setTheme(\(jsString(theme)))")
        }

        // MARK: Content sync

        /// Push content when the document identity changes, or when `content`
        /// was replaced out-of-band (not the echo of the user's own typing).
        func syncContentIfNeeded() {
            guard isReady else { return }
            let identityChanged = parent.identity != loadedIdentity
            let externalChange = parent.content != lastEmitted && parent.content != loadedContent
            guard identityChanged || externalChange else { return }
            loadedIdentity = parent.identity
            pushContent(parent.content)
        }

        private func pushContent(_ markdown: String) {
            loadedContent = markdown
            eval("window.oakEditor && window.oakEditor.setMarkdown(\(jsString(markdown)))")
        }

        // MARK: WKScriptMessageHandler

        public func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "ready":
                isReady = true
                lastTheme = resolvedTheme()
                loadedIdentity = parent.identity
                pushContent(parent.content)

            case "markdown":
                if let md = message.body as? String {
                    lastEmitted = md
                    loadedContent = md
                    parent.onChange(md)
                }

            case "aiRequest":
                handleAIRequest(message.body)

            case "aiCancel":
                if let dict = message.body as? [String: Any], let id = dict["id"] as? Int {
                    aiTasks[id]?.cancel(); aiTasks[id] = nil
                }

            case "imageUpload":
                handleImageUpload(message.body)

            case "refClick":
                if let ref = message.body as? String { parent.onReferenceClick?(ref) }

            case "tagClick":
                if let tag = message.body as? String { parent.onTagClick?(tag) }

            case "textSelected":
                handleTextSelected(message.body)

            case "selectionCleared":
                parent.onSelectionCleared?()

            case "log", "status":
                log.debug("[Milkdown] \(message.name, privacy: .public): \(String(describing: message.body), privacy: .public)")

            default:
                break
            }
        }

        // MARK: Text selection → screen geometry

        /// Convert the JS viewport rect into screen points (same math as the HTML
        /// document viewer) and hand it to the host with an AI trigger.
        private func handleTextSelected(_ body: Any) {
            guard let dict = body as? [String: Any],
                  let text = dict["text"] as? String, !text.isEmpty,
                  let x = dict["x"] as? CGFloat,
                  let y = dict["y"] as? CGFloat,
                  let bottomY = dict["bottomY"] as? CGFloat,
                  let vpWidth = dict["vpWidth"] as? CGFloat, vpWidth > 0,
                  let vpHeight = dict["vpHeight"] as? CGFloat, vpHeight > 0,
                  let webView, let window = webView.window else {
                parent.onSelectionCleared?()
                return
            }

            // WKWebView is flipped (origin top-left, Y down) matching JS viewport
            // coords, so no Y-flip is needed for flipped views.
            let scaleX = webView.bounds.width / vpWidth
            let scaleY = webView.bounds.height / vpHeight
            let topY = webView.isFlipped ? y * scaleY : webView.bounds.height - y * scaleY
            let topPoint = window.convertPoint(toScreen: webView.convert(NSPoint(x: x * scaleX, y: topY), to: nil))
            let botY = webView.isFlipped ? bottomY * scaleY : webView.bounds.height - bottomY * scaleY
            let botPoint = window.convertPoint(toScreen: webView.convert(NSPoint(x: x * scaleX, y: botY), to: nil))

            parent.onSelection?(EditorSelection(
                text: text,
                topScreenPoint: topPoint,
                bottomScreenPoint: botPoint,
                runAI: { [weak self] instruction in
                    guard let self else { return }
                    self.eval("window.oakEditor && window.oakEditor.runAI(\(self.jsString(instruction)))")
                }
            ))
        }

        // MARK: AI streaming

        private func handleAIRequest(_ body: Any) {
            guard let dict = body as? [String: Any], let id = dict["id"] as? Int else { return }
            guard let cfg = parent.aiConfig else {
                eval("window.oakEditor && window.oakEditor.__aiError(\(id), \(jsString("AI is not configured")))")
                return
            }
            let document = dict["document"] as? String ?? ""
            let selection = dict["selection"] as? String ?? ""
            let instruction = dict["instruction"] as? String ?? ""

            var userPrompt = "<document>\n\(document)\n</document>\n"
            if !selection.isEmpty { userPrompt += "<selection>\n\(selection)\n</selection>\n" }
            userPrompt += "\nInstruction: \(instruction)"

            let config = ProviderConfig(providerId: cfg.providerId, model: cfg.model)
            let messages = [LLMMessage(role: .user, text: userPrompt)]
            let router = self.router

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let svc = try router.provider(for: config)
                    let stream = svc.sendMessage(
                        messages: messages, model: cfg.model,
                        systemPrompt: cfg.systemPrompt, maxTokens: cfg.maxTokens
                    )
                    for try await chunk in stream {
                        if Task.isCancelled { return }
                        switch chunk {
                        case .delta(let d):
                            self.eval("window.oakEditor && window.oakEditor.__aiChunk(\(id), \(self.jsString(d)))")
                        case .error(let msg):
                            self.eval("window.oakEditor && window.oakEditor.__aiError(\(id), \(self.jsString(msg)))")
                            self.aiTasks[id] = nil; return
                        case .thinking, .toolUse, .toolInputDelta, .finished:
                            break
                        }
                    }
                    self.eval("window.oakEditor && window.oakEditor.__aiDone(\(id))")
                } catch {
                    if !(error is CancellationError) {
                        self.eval("window.oakEditor && window.oakEditor.__aiError(\(id), \(self.jsString(error.localizedDescription)))")
                    }
                }
                self.aiTasks[id] = nil
            }
            aiTasks[id] = task
        }

        // MARK: Image upload

        private func handleImageUpload(_ body: Any) {
            guard let dict = body as? [String: Any], let id = dict["id"] as? Int,
                  let base64 = dict["base64"] as? String, let data = Data(base64Encoded: base64) else { return }
            let ext = (dict["ext"] as? String) ?? "png"
            let path = parent.imageUploader?(data, ext) ?? ""
            eval("window.oakEditor && window.oakEditor.__imageUploaded(\(id), \(jsString(path)))")
        }

        // MARK: Helpers

        private func eval(_ js: String) { webView?.evaluateJavaScript(js, completionHandler: nil) }

        /// JSON-encode a Swift string into a safe JS string literal.
        private func jsString(_ s: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [s]),
                  let json = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(json.dropFirst().dropLast())
        }

        // MARK: WKNavigationDelegate

        public func webView(_ webView: WKWebView,
                            decidePolicyFor navigationAction: WKNavigationAction,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url); decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
}
