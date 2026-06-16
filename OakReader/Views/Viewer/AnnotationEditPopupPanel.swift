import AppKit
import PDFKit

/// Floating popup that appears when the user clicks an existing PDF annotation
/// (highlight / underline / note / shape). Mirror of `TextSelectionPopupPanel`
/// but for the **re-edit** lifecycle: where the selection popup builds a new
/// annotation from raw text, this one edits the properties of an annotation
/// that already exists in the document.
///
/// Three Marshall-style rows separated by dividers:
///
/// 1. **Color row** — sticky last-used + chevron (deferred for now: just 5
///    fixed palette colors). Changes `annotation.color` via
///    `AnnotationViewModel.updateAnnotationColor`.
/// 2. **Ephemeral AI row** — Ask AI / Translate / Speak, all operating on the
///    *highlighted text* (derived from `page.selection(for: bounds)?.string`).
///    These are transient operations that don't mutate the annotation itself.
/// 3. **Utility row** — Copy text, Delete annotation.
///
/// **Why click instead of right-click as the primary entry.** Direct
/// manipulation (Shneiderman) — clicking the object reveals what you can do to
/// it, without a discovery context-menu intermediary. Right-click still works
/// via `buildAnnotationContextMenu` as a parallel modeless alternative.
final class AnnotationEditPopupPanel: NSPanel, AppResignDismissable {
    private let viewModel: DocumentViewModel
    private let annotation: PDFAnnotation
    private weak var pdfView: PDFView?
    private let onDismiss: () -> Void

    private let anchorPage: PDFPage
    private let anchorBounds: CGRect  // PDF page coords
    private var scrollObserver: NSObjectProtocol?
    var resignObserver: NSObjectProtocol?

    /// Palette presented in the color row. First five colors from
    /// `OakStyle.AnnotationColors` — the longer chevron-expanded palette is
    /// a follow-up (see Phase 2 polish task).
    private static let presetColors: [(NSColor, String)] = [
        (NSColor(red: 1.0,  green: 0.83, blue: 0.0,  alpha: 1.0), "Yellow"),
        (NSColor(red: 1.0,  green: 0.4,  blue: 0.4,  alpha: 1.0), "Red"),
        (NSColor(red: 0.37, green: 0.70, blue: 0.21, alpha: 1.0), "Green"),
        (NSColor(red: 0.18, green: 0.66, blue: 0.90, alpha: 1.0), "Blue"),
        (NSColor(red: 0.64, green: 0.54, blue: 0.90, alpha: 1.0), "Purple"),
    ]

    /// Returns true if the given window belongs to this popup.
    func ownsWindow(_ window: NSWindow) -> Bool { window === self }

    init(
        viewModel: DocumentViewModel,
        annotation: PDFAnnotation,
        pdfView: PDFView,
        anchorPage: PDFPage,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.annotation = annotation
        self.pdfView = pdfView
        self.anchorPage = anchorPage
        self.anchorBounds = annotation.bounds
        self.onDismiss = onDismiss

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.hasShadow = true
        self.ignoresMouseEvents = false

        let contentView = buildContentView()
        self.contentView = contentView

        let size = contentView.fittingSize
        self.setContentSize(size)
        positionAtAnchor()
        animatePopupEntrance(self)

        observeScroll()
        observeAppResign()
    }

    // MARK: - Positioning

    private func positionAtAnchor() {
        let screenPoint = anchorTopScreenPoint() ?? .zero
        let size = self.frame.size
        var x = screenPoint.x - size.width / 2
        var y = screenPoint.y + 6

        // The panel isn't ordered on-screen yet, so `self.screen` is nil; using
        // it would fall back to `NSScreen.main` and yank the panel onto the
        // primary monitor. Resolve the screen from the anchor point instead.
        if let screen = screenContaining(screenPoint) {
            let visible = screen.visibleFrame
            // Flip below if it would clip the top edge.
            if y + size.height > visible.maxY {
                let bottomScreen = anchorBottomScreenPoint() ?? screenPoint
                y = bottomScreen.y - size.height - 6
            }
            // Clamp horizontally to keep the panel on-screen.
            x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
        }
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Top-center of the annotation in screen coords.
    private func anchorTopScreenPoint() -> NSPoint? {
        guard let pdfView, let window = pdfView.window else { return nil }
        let pagePoint = NSPoint(x: anchorBounds.midX, y: anchorBounds.maxY)
        let viewPoint = pdfView.convert(pagePoint, from: anchorPage)
        let windowPoint = pdfView.convert(viewPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    /// Bottom-center of the annotation in screen coords (for flip fallback).
    private func anchorBottomScreenPoint() -> NSPoint? {
        guard let pdfView, let window = pdfView.window else { return nil }
        let pagePoint = NSPoint(x: anchorBounds.midX, y: anchorBounds.minY)
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

    // MARK: - Content

    private func buildContentView() -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.spacing = 4
        mainStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        mainStack.alignment = .centerY

        // Row 1 — persistent (Marshall): color palette
        for (color, name) in Self.presetColors {
            let dot = ColorDotView(color: color, size: 20) { [weak self] in
                self?.applyColor(color)
            }
            dot.toolTip = name
            mainStack.addArrangedSubview(dot)
        }

        mainStack.addArrangedSubview(makeVerticalSeparator())

        // Row 2 — ephemeral AI: Ask / Translate / Speak
        let askBtn = PopupIconButton(
            systemImage: "sparkles",
            accessibilityLabel: "Ask AI About This"
        ) { [weak self] in self?.askAI() }
        mainStack.addArrangedSubview(askBtn)

        if Preferences.shared.isExtensionEnabled(.translation) {
            let translateBtn = PopupIconButton(
                systemImage: "translate",
                accessibilityLabel: "Translate"
            ) { [weak self] in self?.translate() }
            mainStack.addArrangedSubview(translateBtn)
        }

        let speakBtn = PopupIconButton(
            systemImage: "speaker.wave.2",
            accessibilityLabel: "Speak"
        ) { [weak self] in self?.speak() }
        mainStack.addArrangedSubview(speakBtn)

        mainStack.addArrangedSubview(makeVerticalSeparator())

        // Row 3 — utility: copy text + delete
        let copyBtn = PopupIconButton(
            systemImage: "doc.on.doc",
            accessibilityLabel: "Copy Highlighted Text"
        ) { [weak self] in self?.copyText() }
        mainStack.addArrangedSubview(copyBtn)

        let deleteBtn = PopupIconButton(
            systemImage: "trash",
            accessibilityLabel: "Delete Annotation"
        ) { [weak self] in self?.deleteAnnotation() }
        mainStack.addArrangedSubview(deleteBtn)

        return makePopupGlassContainer(content: mainStack)
    }

    private func makeVerticalSeparator() -> NSView {
        makePopupVerticalSeparator()
    }

    // MARK: - Derived selection text

    /// The text the annotation visually covers — derived from the page using
    /// the annotation's bounds. This is what Translate / Speak / Copy and AI
    /// Ask all operate on, since the annotation itself only stores style and
    /// quad points, not the marked-up string.
    private var highlightedText: String? {
        guard let selection = anchorPage.selection(for: anchorBounds),
              let str = selection.string,
              !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return str
    }

    private var pageIndex: Int {
        guard let doc = pdfView?.document else { return 0 }
        return doc.index(for: anchorPage)
    }

    // MARK: - Actions

    private func applyColor(_ color: NSColor) {
        viewModel.annotation.updateAnnotationColor(annotation, color: color)
        // Stay open — user may want to keep iterating on this annotation.
    }

    private func askAI() {
        guard let text = highlightedText else { dismiss(); return }
        viewModel.chat.addTextAttachment(text, pageIndex: pageIndex)
        viewModel.state.rightPanelMode = .aiChat
        dismiss()
    }

    private func translate() {
        guard let text = highlightedText else { dismiss(); return }
        viewModel.translation.setSourceText(text)
        viewModel.state.rightPanelMode = .translation
        dismiss()
    }

    private func speak() {
        let voice = viewModel.voice
        if voice.isSpeaking {
            voice.stopSpeaking()
            return
        }
        guard let text = highlightedText else { return }
        voice.speakText(text)
    }

    private func copyText() {
        guard let text = highlightedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        dismiss()
    }

    private func deleteAnnotation() {
        viewModel.annotation.deleteAnnotation(annotation)
        dismiss()
    }

    // MARK: - Dismiss

    func dismiss() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        removeAppResignObserver()
        viewModel.voice.stopSpeaking()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onDismiss()
        })
    }
}
