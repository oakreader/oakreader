import Foundation
import Observation
import PDFKit
import AppKit

// MARK: - Text Selection Popup Panel (horizontal toolbar above selection)

class TextSelectionPopupPanel: NSPanel, AppResignDismissable {
    private let viewModel: DocumentViewModel
    private let selection: PDFSelection
    private weak var pdfView: PDFView?
    private let onDismiss: () -> Void

    var autoHighlightOnDismiss = false

    /// Returns true if the given window belongs to this popup or its color sub-panel.
    func ownsWindow(_ window: NSWindow) -> Bool {
        return window === self
    }

    private let anchorPage: PDFPage
    private let anchorPoint: NSPoint // PDF page coords: midX of selection, maxY (top)
    private var scrollObserver: NSObjectProtocol?
    var resignObserver: NSObjectProtocol?

    // Speak button
    private weak var speakButton: PopupIconButton?

    init(at screenPoint: NSPoint, viewModel: DocumentViewModel, selection: PDFSelection, pdfView: PDFView, anchorPage: PDFPage, anchorPoint: NSPoint, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.selection = selection
        self.pdfView = pdfView
        self.anchorPage = anchorPage
        self.anchorPoint = anchorPoint
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

        let contentSize = contentView.fittingSize
        self.setContentSize(contentSize)

        // Position: centered above selection
        let x = screenPoint.x - contentSize.width / 2
        var y = screenPoint.y + 6

        // Fallback: if panel top edge exceeds screen top, position below.
        // Resolve the screen from the anchor point so we use the right monitor
        // (the panel isn't ordered on-screen yet, so `window.screen`/`self.screen`
        // can't help).
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
            ?? pdfView.window?.screen ?? NSScreen.main {
            let screenTop = screen.visibleFrame.maxY
            if y + contentSize.height > screenTop {
                y = screenPoint.y - contentSize.height - 6
            }
        }

        self.setFrameOrigin(NSPoint(x: x, y: y))
        animatePopupEntrance(self)

        observeScroll()
        observeAppResign()
    }

    private func observeScroll() {
        guard let pdfView else { return }
        if let scrollView = pdfView.enclosingScrollView ?? pdfView.subviews.compactMap({ $0 as? NSScrollView }).first {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.updatePosition()
            }
        }
    }

    func updatePosition() {
        guard let pdfView, let window = pdfView.window else { return }
        let viewPoint = pdfView.convert(anchorPoint, from: anchorPage)
        let windowPoint = pdfView.convert(viewPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        let panelSize = self.frame.size
        let x = screenPoint.x - panelSize.width / 2
        var y = screenPoint.y + 6

        // Fallback: if panel top edge exceeds screen top, position below
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
            ?? window.screen ?? NSScreen.main {
            let screenTop = screen.visibleFrame.maxY
            if y + panelSize.height > screenTop {
                y = screenPoint.y - panelSize.height - 6
            }
        }

        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Content View (horizontal toolbar)

    private func buildContentView() -> NSView {
        // Two logical groups separated by a divider: send the selection
        // elsewhere (chat/translate/note) | utility (speak/copy).
        // Spacing is wider around the divider than within groups so the
        // grouping is visible at a glance — Gestalt proximity.
        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.spacing = 4
        mainStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        mainStack.alignment = .centerY

        // Markup is no longer offered here. The PDF toolbar arms highlight /
        // underline / strikethrough, so a reader marking up a document drags
        // across text and the markup lands on mouse-up — no trip to a popup,
        // once per passage. What was left in this popup was a slower second
        // path to the same instruments, plus a colour palette that set the very
        // same global `strokeColor` the toolbar's menu sets.
        //
        // Nothing is lost: ⌃⌘H / ⌃⌘U still apply to the current selection from
        // the Edit menu, and Note below still creates a highlight carrying a
        // comment. This popup is now one idea — do something *else* with the
        // selection — while the toolbar owns marking it up. (See ADR-038, whose
        // split-button markup group this supersedes for PDFs. The HTML popup
        // keeps its markup group: the web viewer has no armed-markup toolbar,
        // so removing it there would lose the capability outright.)

        // Group 2: Send selection elsewhere (chat + translate + note)
        let chatBtn = PopupIconButton(
            systemImage: "bubble.left.and.bubble.right",
            accessibilityLabel: "Add to Chat"
        ) { [weak self] in
            self?.addToChat()
        }
        mainStack.addArrangedSubview(chatBtn)

        if Preferences.shared.isExtensionEnabled(.translation) {
            let translateBtn = PopupIconButton(
                systemImage: "translate",
                accessibilityLabel: "Translate"
            ) { [weak self] in
                self?.translateSelection()
            }
            mainStack.addArrangedSubview(translateBtn)
        }

        if Preferences.shared.isExtensionEnabled(.notes) {
            let noteBtn = PopupIconButton(
                systemImage: "note.text",
                accessibilityLabel: "Add Note"
            ) { [weak self] in
                self?.addNote()
            }
            mainStack.addArrangedSubview(noteBtn)
        }

        // Separator 2
        mainStack.addArrangedSubview(makeVerticalSeparator())

        // Group 3: Utility (speak + copy)
        let speakBtn = PopupIconButton(
            systemImage: "speaker.wave.2",
            accessibilityLabel: "Play Sound"
        ) { [weak self] in
            self?.speakSelection()
        }
        self.speakButton = speakBtn
        mainStack.addArrangedSubview(speakBtn)

        let copyBtn = PopupIconButton(
            systemImage: "square.on.square",
            accessibilityLabel: "Copy"
        ) { [weak self] in
            self?.copySelection()
        }
        mainStack.addArrangedSubview(copyBtn)

        // Background container
        return makePopupGlassContainer(content: mainStack)
    }

    private func makeVerticalSeparator() -> NSView {
        makePopupVerticalSeparator()
    }


    // MARK: - Actions

    private func addToChat() {
        guard let text = selection.string, !text.isEmpty else { return }
        let pageIndex = viewModel.state.currentPageIndex
        viewModel.chat.addTextAttachment(text, pageIndex: pageIndex)
        viewModel.state.rightPanelMode = .aiChat
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func translateSelection() {
        guard let text = selection.string, !text.isEmpty else { return }
        viewModel.translation.setSourceText(text)
        viewModel.state.rightPanelMode = .translation
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func speakSelection() {
        let voice = viewModel.voice
        if voice.isSpeaking {
            voice.stopSpeaking()
            speakButton?.updateImage(systemImage: "speaker.wave.2")
            return
        }

        guard let text = selection.string, !text.isEmpty else { return }
        voice.speakText(text)
        speakButton?.updateImage(systemImage: "stop.fill")
        observeSpeakingState()
    }

    private func observeSpeakingState() {
        withObservationTracking {
            _ = self.viewModel.voice.isSpeaking
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.viewModel.voice.isSpeaking {
                    self.observeSpeakingState()
                } else {
                    self.speakButton?.updateImage(systemImage: "speaker.wave.2")
                }
            }
        }
    }

    /// Create a note on the selection and open the Markdown editor for it. The
    /// markup is created synchronously (so the editor can look it up by id);
    /// opening the editor is posted to the coordinator.
    private func addNote() {
        autoHighlightOnDismiss = false
        if let id = viewModel.annotation.addNote(for: selection) {
            NotificationCenter.default.post(name: .openNoteEditor, object: viewModel, userInfo: ["id": id])
        }
        pdfView?.clearSelection()
        dismiss()
    }

    private func copySelection() {
        if let text = selection.string {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func dismissWithAction() {
        autoHighlightOnDismiss = false
        dismiss()
    }

    func dismiss() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        removeAppResignObserver()

        // Stop TTS playback if active
        viewModel.voice.stopSpeaking()

        // Dismiss color sub-panel

        if autoHighlightOnDismiss {
            autoHighlightOnDismiss = false
            viewModel.annotation.addHighlight(for: selection)
            pdfView?.clearSelection()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onDismiss()
        })
    }
}

// MARK: - Annotation Color Change Helper

class AnnotationColorChange: NSObject {
    let annotation: PDFAnnotation
    let color: NSColor

    init(annotation: PDFAnnotation, color: NSColor) {
        self.annotation = annotation
        self.color = color
    }
}

/// Carries a recolor request for a DB-backed overlay markup (identified by its
/// DB id rather than a `PDFAnnotation`).
class OverlayColorChange: NSObject {
    let id: String
    let color: NSColor

    init(id: String, color: NSColor) {
        self.id = id
        self.color = color
    }
}
