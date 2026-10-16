import AppKit
import JavaScriptCore
import Observation
@_spi(Textual) import SwiftUIMath
import WebKit

/// Which engine draws a formula. SwiftUIMath first, KaTeX when it cannot.
///
/// The order and the CJK rule come from ChatGPT's native app: its `IosMathLabelBuilder`
/// rejects non-Latin characters, then `KatexMathLabelBuilder` runs KaTeX in
/// JavaScriptCore and lets WebKit draw the MathML. SwiftUIMath is the same iosMath
/// engine; its math fonts have no CJK glyphs, so `\text{速度}` comes out blank.
@MainActor
enum MathRoute {
    /// True when the formula holds text the Latin Modern math font has no glyphs for.
    ///
    /// ChatGPT's `IosMathLabelBuilder` rejects anything outside the Latin script plus
    /// ASCII punctuation, because iosMath draws a missing glyph as a blank and still
    /// reports a size. Greek, letterlike symbols (ℝ) and math alphanumerics stay
    /// native here: the math font has them, and models type them straight in.
    static func hasNonLatinText(_ latex: String) -> Bool {
        latex.unicodeScalars.contains { scalar in
            let v = scalar.value
            if v < 0x80 { return false }
            if (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v) { return true }
            if scalar.properties.isEmojiPresentation { return true }
            guard scalar.properties.isAlphabetic else { return false }
            let drawable: [ClosedRange<UInt32>] = [
                0x00C0...0x024F, 0x1E00...0x1EFF,   // Latin
                0x0370...0x03FF, 0x1F00...0x1FFF,   // Greek
                0x2100...0x214F,                    // letterlike symbols
                0x1D400...0x1D7FF,                  // math alphanumerics
            ]
            return !drawable.contains { $0.contains(v) }
        }
    }

    /// True when SwiftUIMath parses and lays out the formula. An unknown command or
    /// a stray brace fails the whole formula, and the view then draws nothing.
    static func nativeCanDraw(_ latex: String, display: Bool, fontSize: CGFloat) -> Bool {
        guard !hasNonLatinText(latex) else { return false }
        let normalized = MarkdownCompat.normalizeLaTeX(latex)
        let ok = measures(normalized, display: display, fontSize: fontSize)
        if ok {
            MathRenderStats.record(.native, latex: latex, display: display)
        } else {
            MathRenderStats.noteUnknownCommands(in: normalized) { measures($0, display: false, fontSize: fontSize) }
        }
        return ok
    }

    static func measures(_ latex: String, display: Bool, fontSize: CGFloat) -> Bool {
        Math.typographicBounds(
            for: latex,
            fitting: .unspecified,
            font: .init(name: .latinModern, size: fontSize),
            style: display ? .display : .text).width > 0
    }
}

/// Which renderer drew each formula, and which commands SwiftUIMath did not know.
///
/// ChatGPT logs `latex_parsing_success_iosmath`, `_katex` and `latex_parsing_failure`,
/// and each unknown command once (`errorLoggedCommands`). Those counts decide which
/// commands earn a native entry in `LatexCommands`. The host app supplies `sink`;
/// formulas themselves are never sent, only the outcome and command names.
@MainActor
public enum MathRenderStats {
    public enum Renderer: String { case native, katex, failure }

    /// `(event, properties)`. Nil drops everything, which is what tests get.
    public static var sink: ((String, [String: String]) -> Void)?

    private static var recorded: Set<String> = []
    private static var reportedCommands: Set<String> = []
    private static let commandRegex = try! NSRegularExpression(pattern: #"\\([A-Za-z]+)"#)

    /// Once per formula per launch: a streaming reply re-renders the same formula
    /// on every commit.
    static func record(_ renderer: Renderer, latex: String, display: Bool) {
        guard let sink, recorded.insert("\(display)|\(latex)").inserted else { return }
        sink("latex_render", ["renderer": renderer.rawValue, "display": display ? "true" : "false"])
    }

    /// Reports each command in a failed formula that SwiftUIMath cannot draw on its
    /// own, bare or with one or two arguments.
    static func noteUnknownCommands(in latex: String, draws: (String) -> Bool) {
        guard let sink else { return }
        let ns = latex as NSString
        for match in commandRegex.matches(in: latex, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            guard !reportedCommands.contains(name) else { continue }
            let probes = ["\\\(name)", "\\\(name){x}", "\\\(name){x}{y}"]
            if probes.contains(where: draws) { continue }
            reportedCommands.insert(name)
            sink("latex_unknown_command", ["command": name])
        }
    }
}

// MARK: - KaTeX in JavaScriptCore

/// Runs the bundled `katex.min.js` to turn LaTeX into MathML. No DOM, no web view.
@MainActor
final class KatexEngine {
    static let shared = KatexEngine()

    private lazy var render: JSValue? = {
        guard let url = Bundle.module.url(forResource: "katex.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        // KaTeX warns through `console`, which JavaScriptCore does not define.
        context.evaluateScript("var console = { log() {}, warn() {}, error() {} };")
        context.evaluateScript(source)
        // `strict: false` accepts CJK typed straight into math mode, as models write it.
        let function = context.evaluateScript("""
            (function (latex, display) {
              try {
                return katex.renderToString(latex, {
                  output: "mathml", displayMode: display, throwOnError: true, strict: false
                });
              } catch (e) { return null; }
            })
            """)
        return function?.isObject == true ? function : nil
    }()

    /// MathML markup for `latex`, or nil when KaTeX cannot parse it either.
    func mathML(for latex: String, display: Bool) -> String? {
        let latex = latex.replacingOccurrences(of: MarkdownCompat.shim, with: "")
        guard let result = render?.call(withArguments: [latex, display]), result.isString else { return nil }
        return result.toString()
    }
}

// MARK: - MathML drawn by WebKit

/// Draws KaTeX's MathML in one small offscreen `WKWebView` and keeps the snapshots.
///
/// ChatGPT gives each formula its own live web view. A live view cannot sit inside
/// an `NSTextView` line, so this draws each formula once, snapshots it, and hands
/// out the image. Rendering is asynchronous: `lookup` answers `.pending` the first
/// time and bumps `revision` when the image lands. Views that called `lookup` while
/// building their body observe `revision` and rebuild.
@MainActor
@Observable
public final class MathMLRenderer {
    public static let shared = MathMLRenderer()

    public struct Rendered {
        public let image: NSImage
        /// Distance from the baseline to the image's bottom edge.
        public let descent: CGFloat
    }

    enum State {
        case ready(Rendered)
        case pending
        case failed
    }

    /// Bumped each time a formula finishes rendering.
    public private(set) var revision = 0

    @ObservationIgnored private var images: [String: Rendered] = [:]
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var loader: ShellLoader?

    private struct Job {
        let key: String
        let mathML: String
        let fontSize: CGFloat
        let color: String
    }

    func lookup(latex: String, display: Bool, fontSize: CGFloat, color: NSColor) -> State {
        _ = revision
        let css = color.cssColor
        let key = "\(display ? "D" : "T")|\(fontSize)|\(css)|\(latex)"
        if let image = images[key] { return .ready(image) }
        if failed.contains(key) { return .failed }
        if queued.contains(key) { return .pending }
        guard let mathML = KatexEngine.shared.mathML(for: latex, display: display) else {
            failed.insert(key)
            MathRenderStats.record(.failure, latex: latex, display: display)
            return .failed
        }
        MathRenderStats.record(.katex, latex: latex, display: display)
        queued.insert(key)
        jobs.append(Job(key: key, mathML: mathML, fontSize: fontSize, color: css))
        if !running {
            running = true
            Task { await drain() }
        }
        return .pending
    }

    /// Renders `latex` and waits for the image. For tests and one-off callers.
    func render(latex: String, display: Bool, fontSize: CGFloat, color: NSColor) async -> Rendered? {
        while true {
            switch lookup(latex: latex, display: display, fontSize: fontSize, color: color) {
            case .ready(let rendered): return rendered
            case .failed: return nil
            case .pending: try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func drain() async {
        // The window is on screen only while drawing. A visible window, even one parked
        // off screen, keeps the app alive after the user closes the last real one.
        window?.orderFrontRegardless()
        defer { window?.orderOut(nil) }
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            if let rendered = await draw(job) {
                images[job.key] = rendered
            } else {
                failed.insert(job.key)
            }
            queued.remove(job.key)
            revision += 1
        }
        running = false
    }

    private func draw(_ job: Job) async -> Rendered? {
        guard let webView = await readyWebView() else { return nil }
        let script = """
            (function () {
              const box = document.getElementById("c");
              box.style.fontSize = "\(job.fontSize)px";
              box.style.color = "\(job.color)";
              box.innerHTML = \(job.mathML.jsStringLiteral) + '<span id="b"></span>';
              const r = box.getBoundingClientRect();
              const b = document.getElementById("b").getBoundingClientRect();
              return [r.width, r.height, r.bottom - b.top];
            })()
            """
        guard let metrics = try? await webView.evaluateJavaScript(script) as? [Double],
              metrics.count == 3, metrics[0] > 0, metrics[1] > 0 else { return nil }
        let size = CGSize(width: ceil(metrics[0]), height: ceil(metrics[1]))
        if size.width > webView.frame.width || size.height > webView.frame.height {
            window?.setContentSize(CGSize(width: max(size.width, webView.frame.width),
                                          height: max(size.height, webView.frame.height)))
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        return Rendered(image: image, descent: CGFloat(metrics[2]))
    }

    private func readyWebView() async -> WKWebView? {
        if let webView { return webView }
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 400)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        // A clear page, so the snapshot sits on any bubble background.
        webView.setValue(false, forKey: "drawsBackground")
        // WebKit stops painting a view that has no window, so park one off screen.
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = webView
        window.orderFrontRegardless()
        let loader = ShellLoader()
        webView.navigationDelegate = loader
        self.loader = loader
        self.window = window
        guard await loader.load(Self.shell, in: webView) else { return nil }
        self.webView = webView
        return webView
    }

    /// The `b` span is a zero-height inline block; its top edge is the baseline.
    private static let shell = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html, body { margin: 0; padding: 0; background: transparent; }
        #c { display: inline-block; padding: 1px 1px 2px; white-space: nowrap;
             font-family: -apple-system, "PingFang SC", sans-serif; }
        #b { display: inline-block; width: 0; height: 0; }
        math { font-family: "STIX Two Math", "Latin Modern Math", math; }
        math[display="block"] { margin: 0; }
        </style></head><body><span id="c"></span></body></html>
        """
}

@MainActor
private final class ShellLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func load(_ html: String, in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(false)
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }
}

private extension NSColor {
    /// `rgba(…)` for CSS. Resolves a dynamic color against the current appearance.
    var cssColor: String {
        guard let c = usingColorSpace(.sRGB) else { return "rgba(0,0,0,1)" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return "rgba(\(r),\(g),\(b),\(String(format: "%.3f", c.alphaComponent)))"
    }
}

private extension String {
    /// The string as a JavaScript string literal.
    var jsStringLiteral: String {
        let data = try? JSONSerialization.data(withJSONObject: [self])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
