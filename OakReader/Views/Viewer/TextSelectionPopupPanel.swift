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
        return window === self || window === colorSubPanel
    }

    private let anchorPage: PDFPage
    private let anchorPoint: NSPoint // PDF page coords: midX of selection, maxY (top)
    private var scrollObserver: NSObjectProtocol?
    var resignObserver: NSObjectProtocol?

    // Color sub-panel
    private var colorSubPanel: NSPanel?

    // Speak button
    private weak var speakButton: PopupIconButton?

    static let annotationColors: [(NSColor, String)] = [
        (NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0), "Yellow"),
        (NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0), "Red"),
        (NSColor(red: 0.37, green: 0.70, blue: 0.21, alpha: 1.0), "Green"),
        (NSColor(red: 0.18, green: 0.66, blue: 0.90, alpha: 1.0), "Blue"),
        (NSColor(red: 0.64, green: 0.54, blue: 0.90, alpha: 1.0), "Purple"),
        (NSColor(red: 0.90, green: 0.43, blue: 0.93, alpha: 1.0), "Magenta"),
        (NSColor(red: 0.95, green: 0.60, blue: 0.22, alpha: 1.0), "Orange"),
        (NSColor(red: 0.67, green: 0.67, blue: 0.67, alpha: 1.0), "Gray"),
    ]

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

        // Fallback: if panel top edge exceeds screen top, position below
        if let screen = NSScreen.main {
            let screenTop = screen.visibleFrame.maxY
            if y + contentSize.height > screenTop {
                y = screenPoint.y - contentSize.height - 6
            }
        }

        self.setFrameOrigin(NSPoint(x: x, y: y))
        self.orderFront(nil)

        self.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 1
        }

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
        if let screen = window.screen ?? NSScreen.main {
            let screenTop = screen.visibleFrame.maxY
            if y + panelSize.height > screenTop {
                y = screenPoint.y - panelSize.height - 6
            }
        }

        self.setFrameOrigin(NSPoint(x: x, y: y))

        // Reposition color sub-panel if visible
        repositionColorSubPanel()
    }

    // MARK: - Content View (horizontal toolbar)

    private func buildContentView() -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.spacing = 2
        mainStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        mainStack.alignment = .centerY

        // Group 1: Markup (highlight + underline + color picker)
        let highlightBtn = PopupIconButton(
            systemImage: "highlighter",
            accessibilityLabel: "Highlight"
        ) { [weak self] in
            self?.applyHighlight(
                color: self?.viewModel.annotation.strokeColor
                    ?? NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0)
            )
        }
        mainStack.addArrangedSubview(highlightBtn)

        let underlineBtn = PopupIconButton(
            systemImage: "underline",
            accessibilityLabel: "Underline"
        ) { [weak self] in
            self?.applyUnderline()
        }
        mainStack.addArrangedSubview(underlineBtn)

        let colorBtn = PopupIconButton(
            systemImage: "paintpalette",
            accessibilityLabel: "Annotation Color"
        ) { [weak self] in
            self?.toggleColorSubPanel()
        }
        mainStack.addArrangedSubview(colorBtn)

        // Separator 1
        mainStack.addArrangedSubview(makeVerticalSeparator())

        // Group 2: Actions (chat + note)
        let chatBtn = PopupIconButton(
            systemImage: "bubble.left",
            accessibilityLabel: "Add to Chat"
        ) { [weak self] in
            self?.addToChat()
        }
        mainStack.addArrangedSubview(chatBtn)

        if Preferences.shared.isExtensionEnabled(.notes) {
            let noteBtn = PopupIconButton(
                systemImage: "note.text.badge.plus",
                accessibilityLabel: "Add to Note"
            ) { [weak self] in
                self?.addToNote()
            }
            mainStack.addArrangedSubview(noteBtn)
        }

        if Preferences.shared.isExtensionEnabled(.translation) {
            let translateBtn = PopupIconButton(
                systemImage: "translate",
                accessibilityLabel: "Translate"
            ) { [weak self] in
                self?.translateSelection()
            }
            mainStack.addArrangedSubview(translateBtn)
        }

        let speakBtn = PopupIconButton(
            systemImage: "speaker.wave.2",
            accessibilityLabel: "Play Sound"
        ) { [weak self] in
            self?.speakSelection()
        }
        self.speakButton = speakBtn
        mainStack.addArrangedSubview(speakBtn)

        if Preferences.shared.isExtensionEnabled(.flashcards) {
            let quizBtn = PopupIconButton(
                systemImage: "sparkles",
                accessibilityLabel: "Generate Quiz"
            ) { [weak self] in
                self?.generateQuiz()
            }
            mainStack.addArrangedSubview(quizBtn)
        }

        // Separator 2
        mainStack.addArrangedSubview(makeVerticalSeparator())

        // Group 3: Clipboard (copy)
        let copyBtn = PopupIconButton(
            systemImage: "doc.on.doc",
            accessibilityLabel: "Copy"
        ) { [weak self] in
            self?.copySelection()
        }
        mainStack.addArrangedSubview(copyBtn)

        // Background container
        return makePopupGlassContainer(content: mainStack)
    }

    private func makeVerticalSeparator() -> NSView {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        // Rotate separator to be vertical within horizontal stack
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(sep)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalToConstant: 1),
            wrapper.heightAnchor.constraint(equalToConstant: 20),
            sep.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            sep.topAnchor.constraint(equalTo: wrapper.topAnchor),
            sep.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),
        ])
        return wrapper
    }

    // MARK: - Color Sub-Panel

    private func toggleColorSubPanel() {
        if let panel = colorSubPanel {
            panel.orderOut(nil)
            colorSubPanel = nil
            return
        }
        showColorSubPanel()
    }

    private func showColorSubPanel() {
        let colorStack = NSStackView()
        colorStack.orientation = .horizontal
        colorStack.spacing = 8
        colorStack.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)

        for (color, name) in Self.annotationColors {
            let dot = ColorDotView(color: color, size: 20) { [weak self] in
                self?.applyHighlight(color: color)
            }
            dot.toolTip = name
            colorStack.addArrangedSubview(dot)
        }

        let container = makePopupGlassContainer(content: colorStack)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.contentView = container

        let contentSize = container.fittingSize
        panel.setContentSize(contentSize)

        colorSubPanel = panel
        repositionColorSubPanel()
        panel.orderFront(nil)

        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 1
        }
    }

    private func repositionColorSubPanel() {
        guard let panel = colorSubPanel else { return }
        let mainFrame = self.frame
        let panelSize = panel.frame.size

        // Position below the main toolbar, left-aligned
        let splitOffset: CGFloat = 6
        let x = mainFrame.origin.x + splitOffset
        let y = mainFrame.origin.y - panelSize.height - 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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

    private func addToNote() {
        guard let text = selection.string, !text.isEmpty else { return }
        let pageIndex = viewModel.state.currentPageIndex
        viewModel.notes.addTextToNote(text, pageIndex: pageIndex, source: "PDF")
        viewModel.state.rightPanelMode = .notes
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

    private func generateQuiz() {
        guard let text = selection.string, !text.isEmpty else { return }
        guard text.count >= 10 else { return } // Minimum length check

        // Create purple quiz-source highlight
        let annotationId = viewModel.annotation.addQuizHighlight(for: selection)

        // Get page context
        let pageContext: String
        if let pdfDoc = viewModel.pdfDocument,
           let page = pdfDoc.page(at: viewModel.state.currentPageIndex) {
            pageContext = TextExtractionService().extractText(from: page)
        } else {
            pageContext = text
        }

        let documentTitle = viewModel.libraryItem?.title ?? viewModel.fileName
        let itemId = viewModel.itemId ?? ""

        // Dismiss toolbar immediately — user continues reading
        pdfView?.clearSelection()
        dismissWithAction()

        // Kick off background generation
        guard let database = viewModel.database, !itemId.isEmpty, let annotationId else { return }
        let service = QuizGenerationService(database: database)

        Task {
            do {
                let cards = try await service.generateFromHighlight(
                    sourceText: text,
                    pageContext: String(pageContext.prefix(4_000)),
                    documentTitle: documentTitle,
                    itemId: itemId,
                    annotationId: annotationId
                )
                await MainActor.run {
                    viewModel.appState?.importNotification = "Generated \(cards.count) quiz card\(cards.count == 1 ? "" : "s")"
                    viewModel.flashcards.loadCards()
                }
            } catch {
                Log.error(Log.store, "Quiz generation failed: \(error)")
                await MainActor.run {
                    viewModel.appState?.importNotification = "Quiz generation failed"
                }
            }
        }
    }

    private func applyHighlight(color: NSColor) {
        viewModel.annotation.strokeColor = color
        viewModel.annotation.addHighlight(for: selection)
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func applyUnderline() {
        viewModel.annotation.addUnderline(for: selection)
        pdfView?.clearSelection()
        dismissWithAction()
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
        colorSubPanel?.orderOut(nil)
        colorSubPanel = nil

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
