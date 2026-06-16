import AppKit
import SwiftUI
import WebKit

/// The note/comment editor for a **web** highlight — the WKWebView sibling of
/// `NoteEditorPopupPanel`. It hosts the same Milkdown `NoteEditorView`, but anchors
/// to a screen rect (rather than PDF page coords) and persists straight to the
/// shared `annotations` table via `AnnotationStore` (no PDF `markupOverlay`).
///
/// Color/kind changes are pushed to the live highlight through `OakHighlighter`
/// (`setStyle`); the comment is written on dismiss and the highlight's note marker
/// toggled via `setHasNote`. A `.commentsDidChange` notification refreshes the
/// right-panel Comments stream.
/// Everything needed to open the note editor for one web highlight.
struct WebNoteTarget {
    let highlightId: String
    let comment: String
    let colorCSS: String      // CSS rgba string (web highlights store color this way)
    let type: String          // "highlight" | "underline"
    let anchorTopScreen: NSPoint
    let anchorBottomScreen: NSPoint
}

final class WebNoteEditorPopupPanel: NSPanel, AppResignDismissable {
    private(set) static var current: WebNoteEditorPopupPanel?

    private let viewModel: DocumentViewModel
    private let highlightId: String
    private weak var webView: WKWebView?
    private let anchorTopScreen: NSPoint
    private let anchorBottomScreen: NSPoint
    private let onDismiss: () -> Void

    private let palette = OakStyle.AnnotationColors.highlightColors
    private var latestComment: String
    private var currentColorCSS: String
    private var currentType: String  // "highlight" | "underline"
    var resignObserver: NSObjectProtocol?

    func ownsWindow(_ window: NSWindow) -> Bool { window === self }

    /// `canBecomeKey` so the embedded WKWebView (Milkdown) receives keystrokes.
    override var canBecomeKey: Bool { true }

    static func show(
        viewModel: DocumentViewModel,
        target: WebNoteTarget,
        webView: WKWebView?,
        onDismiss: @escaping () -> Void
    ) {
        current?.dismiss()
        current = WebNoteEditorPopupPanel(
            viewModel: viewModel,
            target: target,
            webView: webView,
            onDismiss: onDismiss
        )
    }

    static func dismissCurrent() { current?.dismiss() }

    private init(
        viewModel: DocumentViewModel,
        target: WebNoteTarget,
        webView: WKWebView?,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.highlightId = target.highlightId
        self.webView = webView
        self.anchorTopScreen = target.anchorTopScreen
        self.anchorBottomScreen = target.anchorBottomScreen
        self.onDismiss = onDismiss
        self.latestComment = target.comment
        self.currentColorCSS = target.colorCSS
        self.currentType = (target.type == "underline") ? "underline" : "highlight"

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: NoteEditorView.panelWidth, height: NoteEditorView.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.hasShadow = true
        self.ignoresMouseEvents = false

        let colorIndex = Self.colorIndex(fromCSSRGBA: target.colorCSS)
        let kind = PDFMarkupKind(rawValue: currentType) ?? .highlight

        let editor = NoteEditorView(
            initialComment: target.comment,
            initialColorIndex: colorIndex,
            initialKind: kind,
            onColorChange: { [weak self] index in self?.applyColor(index) },
            onKindChange: { [weak self] kind in self?.applyKind(kind) },
            onCommentChange: { [weak self] text in self?.latestComment = text },
            onDelete: { [weak self] in self?.deleteNote() },
            onClose: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingView(rootView: editor)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        self.contentView = hosting
        self.setContentSize(NSSize(width: NoteEditorView.panelWidth, height: NoteEditorView.panelHeight))

        positionAtAnchor()
        animatePopupEntrance(self)
        observeAppResign()
        makeKeyAndOrderFront(nil)
    }

    // MARK: - Persistence (shared annotations table, web rows)

    private var store: AnnotationStore? {
        viewModel.database.map { AnnotationStore(database: $0) }
    }

    /// Fetch the web annotation row, mutate it, and persist.
    private func updateRecord(_ mutate: (inout AnnotationRecord) -> Void) {
        guard let store, var record = store.fetch(id: highlightId) else { return }
        mutate(&record)
        record.updatedAt = Date().iso8601String
        store.upsert(record)
    }

    private func applyColor(_ index: Int) {
        guard palette.indices.contains(index) else { return }
        let css = OakStyle.AnnotationColors.cssRGBA(palette[index].nsColor)
        currentColorCSS = css
        updateRecord { $0.color = css }
        evalJS("OakHighlighter.setStyle('\(Self.jsEscape(highlightId))', '\(Self.jsEscape(css))', '\(currentType)');")
        postChanged()
    }

    private func applyKind(_ kind: PDFMarkupKind) {
        currentType = (kind == .underline) ? "underline" : "highlight"
        updateRecord { $0.type = currentType }
        evalJS("OakHighlighter.setStyle('\(Self.jsEscape(highlightId))', '\(Self.jsEscape(currentColorCSS))', '\(currentType)');")
        postChanged()
    }

    private func deleteNote() {
        evalJS("OakHighlighter.remove('\(Self.jsEscape(highlightId))');")
        store?.softDelete(id: highlightId)
        postChanged()
        closeWithoutSaving()
    }

    /// Persist the comment, toggle the highlight's note marker, then close.
    func dismiss() {
        let trimmed = latestComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored: String? = trimmed.isEmpty ? nil : latestComment
        updateRecord { $0.comment = stored }
        evalJS("OakHighlighter.setHasNote('\(Self.jsEscape(highlightId))', \(stored != nil ? "true" : "false"));")
        postChanged()
        closeWithoutSaving()
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .commentsDidChange, object: viewModel)
    }

    private func evalJS(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Positioning (screen coords, no PDF conversion)

    /// Anchor *below* the selection (the selection popup sat above it), flipping
    /// above if it would clip the bottom of the screen. Mirrors
    /// `NoteEditorPopupPanel.positionAtAnchor` but the points are already screen.
    private func positionAtAnchor() {
        let size = self.frame.size
        var x = anchorBottomScreen.x - size.width / 2
        var y = anchorBottomScreen.y - size.height - 8

        // The panel isn't ordered on-screen yet, so `self.screen` is nil; using
        // it would fall back to `NSScreen.main` and yank the panel onto the
        // primary monitor. Resolve the screen from the anchor point instead.
        if let screen = screenContaining(anchorBottomScreen) {
            let visible = screen.visibleFrame
            if y < visible.minY + 4 {
                y = anchorTopScreen.y + 8
            }
            x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
            y = max(visible.minY + 4, min(y, visible.maxY - size.height - 4))
        }
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The screen whose frame contains `point`, falling back to the web view's
    /// window screen and finally the main screen. Avoids `self.screen`, which is
    /// nil before the panel is ordered on-screen.
    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? webView?.window?.screen
            ?? NSScreen.main
    }

    // MARK: - Dismiss

    private func closeWithoutSaving() {
        removeAppResignObserver()
        let callback = onDismiss
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            if WebNoteEditorPopupPanel.current === self {
                WebNoteEditorPopupPanel.current = nil
            }
            callback()
        })
    }

    // MARK: - Helpers

    /// Escape a string for embedding in a single-quoted JS literal.
    static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// Nearest palette index for a stored web color, which is a CSS `rgba(r,g,b,a)`
    /// string (not a hex like the PDF side).
    static func colorIndex(fromCSSRGBA css: String) -> Int {
        guard let color = nsColor(fromCSSRGBA: css) else { return 0 }
        return NoteEditorPopupPanel.nearestColorIndex(to: color)
    }

    private static func nsColor(fromCSSRGBA css: String) -> NSColor? {
        // Pull the first three integers out of "rgba(r,g,b,a)".
        let nums = css.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
            .compactMap { Int($0) }
        guard nums.count >= 3 else { return nil }
        return NSColor(
            srgbRed: CGFloat(nums[0]) / 255.0,
            green: CGFloat(nums[1]) / 255.0,
            blue: CGFloat(nums[2]) / 255.0,
            alpha: 1.0
        )
    }
}
