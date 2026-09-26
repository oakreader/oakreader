import Foundation
import WebKit

/// Loads and manages WebExtensions via the native `WKWebExtension` API
/// (macOS 15.4+). This is the foundation for running OakReader's own
/// browser-extension (or any WebExtension) inside the in-app browser, instead
/// of hand-injecting scripts.
///
/// Lifecycle so far: load an unpacked extension (a directory with a
/// `manifest.json`, or a `.zip`) into a shared `WKWebExtensionController`, then
/// hand that controller's `webExtensionController` to each live `WKWebView`'s
/// configuration so content scripts run per the manifest's match patterns.
///
/// Still TODO (later slices): map the real tab/window model
/// (`WKWebExtensionTab`/`Window`), permission prompts, and popup hosting.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionController {
    static let shared = WebExtensionController()

    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []

    init() {
        controller = WKWebExtensionController(configuration: .default())
    }

    /// Load an unpacked extension directory (containing `manifest.json`) or a `.zip`.
    @discardableResult
    func loadExtension(at resourceBaseURL: URL) async throws -> WKWebExtensionContext {
        let webExtension = try await WKWebExtension(resourceBaseURL: resourceBaseURL)
        let context = WKWebExtensionContext(for: webExtension)
        try controller.load(context)
        contexts.append(context)
        return context
    }

    func unload(_ context: WKWebExtensionContext) {
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
    }
}
