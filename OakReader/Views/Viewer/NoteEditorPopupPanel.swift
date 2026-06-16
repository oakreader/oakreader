import AppKit
import SwiftUI
import PDFKit

/// Anchored popover hosting the Markdown note editor (`NoteEditorView`) for a
/// single overlay markup. Color/style changes persist immediately (so the
/// highlight updates live); the comment persists on dismiss.
final class NoteEditorPopupPanel: NSPanel, AppResignDismissable {
    private let viewModel: DocumentViewModel
    private let markupId: String
    private weak var pdfView: PDFView?
    private let anchorPage: PDFPage
    private let anchorBounds: CGRect  // PDF page coords
    private let onDismiss: () -> Void

    private let palette = OakStyle.AnnotationColors.highlightColors
    private var latestComment: String
    private var scrollObserver: NSObjectProtocol?
    var resignObserver: NSObjectProtocol?

    func ownsWindow(_ window: NSWindow) -> Bool { window === self }

    /// `canBecomeKey` so the embedded SwiftUI TextEditor receives keystrokes —
    /// `.nonactivatingPanel` keeps the app from being yanked to the foreground.
    override var canBecomeKey: Bool { true }

    init(
        viewModel: DocumentViewModel,
        markupId: String,
        comment: String,
        colorIndex: Int,
        kind: PDFMarkupKind,
        pdfView: PDFView,
        anchorPage: PDFPage,
        anchorBounds: CGRect,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.markupId = markupId
        self.pdfView = pdfView
        self.anchorPage = anchorPage
        self.anchorBounds = anchorBounds
        self.onDismiss = onDismiss
        self.latestComment = comment

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.hasShadow = true
        self.ignoresMouseEvents = false

        let editor = NoteEditorView(
            initialComment: comment,
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
        // Fixed size — the SwiftUI content is fixed-height so the panel never
        // resizes (a resizing panel made the popover drift while typing).
        self.setContentSize(NSSize(width: NoteEditorView.panelWidth, height: NoteEditorView.panelHeight))

        positionAtAnchor()
        animatePopupEntrance(self)
        observeScroll()
        observeAppResign()

        makeKeyAndOrderFront(nil)
    }

    // MARK: - Actions (persisted)

    private func applyColor(_ index: Int) {
        guard palette.indices.contains(index) else { return }
        viewModel.annotation.updateOverlayMarkupColor(id: markupId, color: palette[index].nsColor)
    }

    private func applyKind(_ kind: PDFMarkupKind) {
        viewModel.annotation.updateOverlayMarkupKind(id: markupId, kind: kind)
    }

    private func deleteNote() {
        viewModel.annotation.deleteOverlayMarkup(id: markupId)
        closeWithoutSaving()
    }

    // MARK: - Positioning

    /// Anchor *below* the selection (the selection popup sits above it), with a
    /// flip-up fallback if it would clip the bottom of the screen. Mirrors the
    /// selection popup's logic, inverted.
    private func positionAtAnchor() {
        guard let below = anchorBottomScreenPoint() else { return }
        let size = self.frame.size
        var x = below.x - size.width / 2
        var y = below.y - size.height - 8   // below the selection's bottom edge

        // The panel isn't ordered on-screen yet, so `self.screen` is nil; using
        // it would fall back to `NSScreen.main` and yank the panel onto the
        // primary monitor. Resolve the screen from the anchor point instead.
        if let screen = screenContaining(below) {
            let visible = screen.visibleFrame
            // Clips the bottom of the screen → flip above the selection's top.
            if y < visible.minY + 4 {
                let above = anchorTopScreenPoint() ?? below
                y = above.y + 8
            }
            x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
            y = max(visible.minY + 4, min(y, visible.maxY - size.height - 4))
        }
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func anchorTopScreenPoint() -> NSPoint? {
        screenPoint(at: NSPoint(x: anchorBounds.midX, y: anchorBounds.maxY))
    }

    private func anchorBottomScreenPoint() -> NSPoint? {
        screenPoint(at: NSPoint(x: anchorBounds.midX, y: anchorBounds.minY))
    }

    private func screenPoint(at pagePoint: NSPoint) -> NSPoint? {
        guard let pdfView, let window = pdfView.window else { return nil }
        let viewPoint = pdfView.convert(pagePoint, from: anchorPage)
        let windowPoint = pdfView.convert(viewPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    /// The screen whose frame contains `point`, falling back to the PDF window's
    /// screen and finally the main screen. Avoids `self.screen`, which is nil
    /// before the panel is ordered on-screen.
    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? pdfView?.window?.screen
            ?? NSScreen.main
    }

    private func observeScroll() {
        guard let pdfView else { return }
        if let scrollView = pdfView.enclosingScrollView
            ?? pdfView.subviews.compactMap({ $0 as? NSScrollView }).first {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.positionAtAnchor()
            }
        }
    }

    // MARK: - Dismiss

    /// Persist the comment, then close.
    func dismiss() {
        viewModel.annotation.updateOverlayMarkupComment(id: markupId, comment: latestComment)
        closeWithoutSaving()
    }

    private func closeWithoutSaving() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        removeAppResignObserver()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onDismiss()
        })
    }

    /// Closest palette index to a given color (for the initial selection ring).
    static func nearestColorIndex(to color: NSColor) -> Int {
        let palette = OakStyle.AnnotationColors.highlightColors
        guard let target = color.usingColorSpace(.sRGB) else { return 0 }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, swatch) in palette.enumerated() {
            guard let c = swatch.nsColor.usingColorSpace(.sRGB) else { continue }
            let d = pow(c.redComponent - target.redComponent, 2)
                + pow(c.greenComponent - target.greenComponent, 2)
                + pow(c.blueComponent - target.blueComponent, 2)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}
