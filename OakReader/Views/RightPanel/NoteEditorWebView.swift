import SwiftUI
import WebKit
import MarkdownEditor

/// Custom WKWebView wrapper for the note editor.
/// Uses the MarkdownEditor package's EditorBridge but injects custom CSS
/// after the editor is ready — to remove active-line highlighting,
/// ensure a clean white background, and hide emphasis markers on
/// the active line when the cursor is outside them.
struct NoteEditorWebView: NSViewRepresentable {
    @Binding var text: String
    var configuration: EditorConfiguration
    /// Base URL for resolving relative image paths (e.g., attachments/uuid.png).
    var baseURL: URL?

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView {
        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .nonPersistent()
        // Allow file access so images from the notes directory can be loaded
        wkConfig.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        #if DEBUG
        wkConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = WKWebView(frame: .zero, configuration: wkConfig)
        webView.setValue(false, forKey: "drawsBackground")
        // Start hidden to prevent flash of unstyled CodeMirror theme.
        // The coordinator reveals it after CSS overrides are injected.
        webView.alphaValue = 0

        // Configure bridge
        context.coordinator.webView = webView
        context.coordinator.bridge.configure(with: webView)
        context.coordinator.bridge.delegate = context.coordinator
        context.coordinator.textBinding = $text
        context.coordinator.initialContent = text

        // Copy editor.html into the notes directory and load via loadFileURL.
        // loadHTMLString doesn't grant file system read access, so images
        // loaded via relative paths (attachments/uuid.png) would fail.
        // loadFileURL + allowingReadAccessTo grants real file read permission.
        //
        // We also patch the bundled JS to add "file:" to the image widget's
        // SAFE_PROTOCOLS list, which otherwise blocks file:// image URLs.
        if let srcHTML = Self.editorHTMLURL(),
           let notesDir = baseURL {
            try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
            let destHTML = notesDir.appendingPathComponent(".editor.html")
            // Read, patch, and write the editor HTML
            if var html = try? String(contentsOf: srcHTML, encoding: .utf8) {
                // Add "file:" to the image widget's safe protocol list
                html = html.replacingOccurrences(
                    of: #""http:","https:","data:","blob:""#,
                    with: #""http:","https:","data:","blob:","file:""#
                )
                try? html.write(to: destHTML, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: destHTML)
                try? FileManager.default.copyItem(at: srcHTML, to: destHTML)
            }
            webView.loadFileURL(destHTML, allowingReadAccessTo: notesDir)
        } else if let srcHTML = Self.editorHTMLURL() {
            // Fallback: no notes directory, load from bundle directly
            webView.loadFileURL(srcHTML, allowingReadAccessTo: srcHTML.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        let newTheme: EditorTheme = colorScheme == .dark ? .dark : .light
        if coordinator.currentTheme != newTheme {
            coordinator.currentTheme = newTheme
            Task { @MainActor in
                await coordinator.bridge.setTheme(newTheme)
                // Re-inject CSS after theme change
                coordinator.injectCustomCSS()
            }
        }

        if coordinator.currentConfiguration != configuration {
            coordinator.currentConfiguration = configuration
            Task { @MainActor in
                await coordinator.bridge.updateConfiguration(configuration)
            }
        }

        if text != coordinator.lastKnownContent && !coordinator.isUpdatingBinding {
            coordinator.lastKnownContent = text
            Task { @MainActor in
                try? await coordinator.bridge.setContent(text)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.bridge.cleanup()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, EditorBridgeDelegate {
        let bridge = EditorBridge()
        weak var webView: WKWebView?

        var textBinding: Binding<String>?
        var initialContent: String = ""
        var lastKnownContent: String = ""
        var currentTheme: EditorTheme = .light
        var currentConfiguration: EditorConfiguration = .default
        var isUpdatingBinding = false

        func editorDidChangeContent(_ content: String) {
            guard let binding = textBinding else { return }
            isUpdatingBinding = true
            lastKnownContent = content
            binding.wrappedValue = content
            isUpdatingBinding = false
        }

        func editorDidBecomeReady() {
            Task { @MainActor in
                await bridge.setTheme(currentTheme)
                await bridge.updateConfiguration(currentConfiguration)
                if !initialContent.isEmpty {
                    try? await bridge.setContent(initialContent)
                    lastKnownContent = initialContent
                }
                // Inject custom CSS AFTER the editor is fully initialized
                injectCustomCSS()
                // Reveal the webview now that styling is applied (prevents flash)
                if let wv = self.webView {
                    wv.alphaValue = 1
                }
            }
        }

        func editorDidChangeSelection(_ selection: EditorSelection) {}
        func editorDidFocus() {}
        func editorDidBlur() {}

        // MARK: - Custom CSS Injection

        /// Inject Obsidian/Apple Notes-style CSS overrides after the editor is ready.
        func injectCustomCSS() {
            let prefs = Preferences.shared
            let bodyFont = prefs.noteEditorFontFamily
            let codeFont = prefs.noteEditorCodeFontFamily
            let fontSize = Int(prefs.noteEditorFontSize)
            let lineHeight = prefs.noteEditorLineHeight

            let codeFontSize = max(fontSize - 2, 12)

            // Build CSS as a Swift string, then embed in JS
            let css = [
                "/* Reset */ .cm-activeLine, .cm-focused .cm-activeLine, .cm-activeLineGutter { background-color: transparent !important; }",
                ".cm-editor, .cm-content, .cm-scroller { background-color: transparent !important; }",
                ".cm-gutters { background-color: transparent !important; border-right: none !important; display: none !important; }",
                ".cm-selectionBackground { background-color: rgba(0,122,255,0.15) !important; }",
                ".cm-focused .cm-selectionBackground { background-color: rgba(0,122,255,0.25) !important; }",
                // Layout
                ".cm-editor { font-family: \(bodyFont) !important; font-size: \(fontSize)px !important; line-height: \(lineHeight) !important; caret-color: #007aff !important; }",
                ".cm-editor .cm-content { font-family: \(bodyFont) !important; font-size: \(fontSize)px !important; padding: 0 !important; }",
                ".cm-scroller { padding: 16px 24px !important; }",
                ".cm-line { padding: 1px 2px !important; }",
                // Headings
                ".cm-line .tok-heading1 { font-size: 28px !important; font-weight: 700 !important; letter-spacing: -0.02em !important; }",
                ".cm-line .tok-heading2 { font-size: 22px !important; font-weight: 700 !important; letter-spacing: -0.01em !important; }",
                ".cm-line .tok-heading3 { font-size: 18px !important; font-weight: 600 !important; }",
                ".cm-line .tok-heading4 { font-size: 16px !important; font-weight: 600 !important; }",
                ".cm-line .tok-heading5, .cm-line .tok-heading6 { font-size: 15px !important; font-weight: 600 !important; }",
                ".cm-line:has(.tok-heading1), .cm-line:has(.tok-heading2), .cm-line:has(.tok-heading3) { margin-top: 16px !important; margin-bottom: 4px !important; }",
                ".cm-line .tok-heading.tok-meta, .cm-line .tok-processingInstruction { color: rgba(0,0,0,0.2) !important; }",
                // Bold, italic, strikethrough
                ".cm-line .tok-strong { font-weight: 600 !important; }",
                ".cm-line .tok-emphasis { font-style: italic !important; }",
                ".cm-line .tok-strikethrough { text-decoration: line-through !important; color: rgba(0,0,0,0.45) !important; }",
                // Links
                ".cm-line .tok-link, .cm-line .tok-url { color: #007aff !important; text-decoration: none !important; }",
                // Lists
                ".cm-line .tok-list { color: #007aff !important; font-weight: 500 !important; }",
                // Blockquotes
                ".cm-line:has(.tok-quote) { border-left: 3px solid #007aff !important; padding-left: 14px !important; margin-left: 4px !important; color: rgba(0,0,0,0.65) !important; background-color: rgba(0,122,255,0.03) !important; border-radius: 0 4px 4px 0 !important; }",
                ".cm-line .tok-quote.tok-meta { color: rgba(0,0,0,0.15) !important; }",
                // Inline code
                ".cm-line .tok-monospace { font-family: \(codeFont) !important; font-size: \(codeFontSize)px !important; background-color: rgba(0,0,0,0.05) !important; padding: 2px 5px !important; border-radius: 4px !important; }",
                // Code blocks: fence lines via :has(.tok-meta) excluding headings and quotes
                ".cm-line:has(.tok-meta):not(:has(.tok-heading)):not(:has(.tok-quote)) { background-color: rgba(0,0,0,0.03) !important; font-family: \(codeFont) !important; font-size: \(codeFontSize)px !important; border-radius: 0 !important; padding-left: 12px !important; }",
                // Code block content lines (marked by JS)
                ".oak-code-line { background-color: rgba(0,0,0,0.03) !important; font-family: \(codeFont) !important; font-size: \(codeFontSize)px !important; padding-left: 12px !important; }",
                // Horizontal rule
                ".cm-line .tok-contentSeparator { color: rgba(0,0,0,0.12) !important; }",
                // Images
                ".cm-line img, .cm-image-container { max-width: 100% !important; border-radius: 8px !important; margin: 8px auto !important; display: block !important; }",
                // Math
                ".cm-math-resize-container { display: flex !important; flex-direction: column !important; align-items: center !important; margin: 12px 0 !important; width: 100% !important; }",
                ".cm-math-display { text-align: center !important; }",
                ".cm-math-widget { font-size: 1.05em !important; }",
                // Dark mode
                "@media (prefers-color-scheme: dark) { .cm-editor .cm-content { color: #e5e5e7 !important; caret-color: #0a84ff !important; } .cm-line .tok-heading.tok-meta, .cm-line .tok-processingInstruction { color: rgba(255,255,255,0.18) !important; } .cm-line .tok-strong { color: #f5f5f7 !important; } .cm-line .tok-link, .cm-line .tok-url { color: #0a84ff !important; } .cm-line .tok-list { color: #0a84ff !important; } .cm-line:has(.tok-quote) { border-left-color: #0a84ff !important; color: rgba(255,255,255,0.6) !important; background-color: rgba(10,132,255,0.05) !important; } .cm-line .tok-monospace { background-color: rgba(255,255,255,0.06) !important; } .cm-line .tok-strikethrough { color: rgba(255,255,255,0.35) !important; } .cm-line:has(.tok-meta):not(:has(.tok-heading)):not(:has(.tok-quote)) { background-color: rgba(255,255,255,0.05) !important; } .oak-code-line { background-color: rgba(255,255,255,0.05) !important; } }",
            ].joined(separator: " ")

            let escapedCSS = css.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "")

            let js = """
            (function() {
                var id = 'oak-note-editor-overrides';
                var existing = document.getElementById(id);
                if (existing) existing.remove();
                var style = document.createElement('style');
                style.id = id;
                style.textContent = '\(escapedCSS)';
                document.head.appendChild(style);

                var _raf = 0;
                var fence = String.fromCharCode(96, 96, 96);
                function tagCodeLines() {
                    var c = document.querySelector('.cm-content');
                    if (!c) return;
                    var lines = c.querySelectorAll('.cm-line');
                    var inside = false;
                    for (var i = 0; i < lines.length; i++) {
                        var txt = lines[i].textContent || '';
                        var trimmed = txt.replace(/^\\s+/, '');
                        var isFence = (trimmed.indexOf(fence) === 0);
                        if (isFence) {
                            inside = !inside;
                            lines[i].classList.remove('oak-code-line');
                        } else if (inside) {
                            lines[i].classList.add('oak-code-line');
                        } else {
                            lines[i].classList.remove('oak-code-line');
                        }
                    }
                }
                setTimeout(tagCodeLines, 100);
                setTimeout(tagCodeLines, 300);
                setTimeout(tagCodeLines, 600);
                var mo = new MutationObserver(function() {
                    cancelAnimationFrame(_raf);
                    _raf = requestAnimationFrame(tagCodeLines);
                });
                var ce = document.querySelector('.cm-content');
                if (ce) mo.observe(ce, { childList: true, subtree: true, characterData: true });
            })();
            """
            webView?.evaluateJavaScript(js) { _, error in
                if let error {
                    print("[NoteEditor] CSS injection error: \(error)")
                }
            }
        }
    }
}

// MARK: - Bundle helper

extension NoteEditorWebView {
    /// Locate editor.html from the MarkdownEditor SPM resource bundle.
    static func editorHTMLURL() -> URL? {
        // SPM resource bundles land in the app's Resources directory
        if let bundleURL = Bundle.main.url(forResource: "MarkdownEditor_MarkdownEditor", withExtension: "bundle"),
           let resourceBundle = Bundle(url: bundleURL) {
            return resourceBundle.url(forResource: "editor", withExtension: "html")
        }
        // Fallback: check main bundle directly
        return Bundle.main.url(forResource: "editor", withExtension: "html")
    }
}
