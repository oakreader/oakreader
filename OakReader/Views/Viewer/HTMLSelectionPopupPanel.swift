import AppKit
import WebKit

// MARK: - Web Text Selection Popup Panel

/// Horizontal toolbar popup for text selected in HTML document viewers.
/// Matches the PDF text selection popup style with highlight, chat, note, translate, copy.
class HTMLSelectionPopupPanel: NSPanel, AppResignDismissable {
    private(set) static var current: HTMLSelectionPopupPanel?

    private let viewModel: DocumentViewModel
    private let selectedText: String
    private weak var webView: WKWebView?
    private let onDismiss: () -> Void

    // Speak button (needs state tracking for icon toggle)
    private weak var speakButton: PopupIconButton?

    // Color sub-panel
    private var colorSubPanel: NSPanel?
    var resignObserver: NSObjectProtocol?

    static let highlightColors: [(NSColor, String, String)] = [
        (NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0), "Yellow", "rgba(255,212,0,0.35)"),
        (NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0), "Red", "rgba(255,102,102,0.35)"),
        (NSColor(red: 0.37, green: 0.70, blue: 0.21, alpha: 1.0), "Green", "rgba(94,179,54,0.35)"),
        (NSColor(red: 0.18, green: 0.66, blue: 0.90, alpha: 1.0), "Blue", "rgba(46,168,230,0.35)"),
        (NSColor(red: 0.64, green: 0.54, blue: 0.90, alpha: 1.0), "Purple", "rgba(163,138,230,0.35)"),
        (NSColor(red: 0.90, green: 0.43, blue: 0.93, alpha: 1.0), "Magenta", "rgba(230,110,237,0.35)"),
        (NSColor(red: 0.95, green: 0.60, blue: 0.22, alpha: 1.0), "Orange", "rgba(242,153,56,0.35)"),
        (NSColor(red: 0.67, green: 0.67, blue: 0.67, alpha: 1.0), "Gray", "rgba(171,171,171,0.35)"),
    ]

    static func show(
        atTop topScreenPoint: NSPoint,
        atBottom bottomScreenPoint: NSPoint,
        text: String,
        viewModel: DocumentViewModel,
        webView: WKWebView?,
        onDismiss: @escaping () -> Void
    ) {
        current?.dismiss()

        let panel = HTMLSelectionPopupPanel(
            atTop: topScreenPoint,
            atBottom: bottomScreenPoint,
            text: text,
            viewModel: viewModel,
            webView: webView,
            onDismiss: onDismiss
        )
        current = panel
    }

    static func dismissCurrent() {
        current?.dismiss()
    }

    /// Returns true if the given window belongs to this popup or its color sub-panel.
    func ownsWindow(_ window: NSWindow) -> Bool {
        return window === self || window === colorSubPanel
    }

    /// Reposition the popup to follow scroll.
    func reposition(atTop topScreenPoint: NSPoint, atBottom bottomScreenPoint: NSPoint) {
        let panelSize = self.frame.size
        let x = topScreenPoint.x - panelSize.width / 2
        var y = topScreenPoint.y + 6

        if let screen = NSScreen.main {
            let screenTop = screen.visibleFrame.maxY
            if y + panelSize.height > screenTop {
                y = bottomScreenPoint.y - panelSize.height - 6
            }
        }

        self.setFrameOrigin(NSPoint(x: x, y: y))

        // Reposition color sub-panel if visible
        if let panel = colorSubPanel {
            let mainFrame = self.frame
            let cpSize = panel.frame.size
            let cpX = mainFrame.origin.x + 6
            let cpY = mainFrame.origin.y - cpSize.height - 2
            panel.setFrameOrigin(NSPoint(x: cpX, y: cpY))
        }
    }

    private init(
        atTop topScreenPoint: NSPoint,
        atBottom bottomScreenPoint: NSPoint,
        text: String,
        viewModel: DocumentViewModel,
        webView: WKWebView?,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.selectedText = text
        self.webView = webView
        self.onDismiss = onDismiss

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        ignoresMouseEvents = false
        appearance = NSAppearance(named: .aqua)

        let content = buildContentView()
        self.contentView = content

        let contentSize = content.fittingSize
        setContentSize(contentSize)

        // Position: centered above selection top
        let x = topScreenPoint.x - contentSize.width / 2
        var y = topScreenPoint.y + 6

        // Fallback: if panel top edge exceeds screen top, position below selection bottom
        if let screen = NSScreen.main {
            let screenTop = screen.visibleFrame.maxY
            if y + contentSize.height > screenTop {
                y = bottomScreenPoint.y - contentSize.height - 6
            }
        }

        setFrameOrigin(NSPoint(x: x, y: y))
        orderFront(nil)

        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 1
        }

        observeAppResign()
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
            self?.applyHighlight(colorIndex: 0) // default yellow
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
            accessibilityLabel: "Highlight Color"
        ) { [weak self] in
            self?.toggleColorSubPanel()
        }
        mainStack.addArrangedSubview(colorBtn)

        // Separator 1
        mainStack.addArrangedSubview(makeVerticalSeparator())

        // Group 2: Actions (chat + note + translate)
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
                self?.translateText()
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

        if Preferences.shared.isExtensionEnabled(.quizCards) {
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
            self?.copyText()
        }
        mainStack.addArrangedSubview(copyBtn)

        // Background container
        return makePopupGlassContainer(content: mainStack)
    }

    private func makeVerticalSeparator() -> NSView {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
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

        for (index, (color, name, _)) in Self.highlightColors.enumerated() {
            let dot = ColorDotView(color: color, size: 20) { [weak self] in
                self?.applyHighlight(colorIndex: index)
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
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = container

        let contentSize = container.fittingSize
        panel.setContentSize(contentSize)

        // Position below the main toolbar, left-aligned
        let mainFrame = self.frame
        let x = mainFrame.origin.x + 6
        let y = mainFrame.origin.y - contentSize.height - 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        colorSubPanel = panel
        panel.orderFront(nil)

        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Actions

    private func applyHighlight(colorIndex: Int) {
        guard let webView else {
            dismiss()
            return
        }

        let (_, _, cssColor) = Self.highlightColors[colorIndex]
        webView.evaluateJavaScript(
            "OakHighlighter.highlightSelection('\(cssColor)', 'highlight');",
            completionHandler: nil
        )
        dismiss()
    }

    private func applyUnderline() {
        guard let webView else {
            dismiss()
            return
        }

        let (_, _, cssColor) = Self.highlightColors[0]
        webView.evaluateJavaScript(
            "OakHighlighter.highlightSelection('\(cssColor)', 'underline');",
            completionHandler: nil
        )
        dismiss()
    }

    private func addToChat() {
        viewModel.chat.addTextAttachment(selectedText, pageIndex: 0)
        viewModel.state.rightPanelMode = .aiChat
        dismiss()
    }

    private func addToNote() {
        viewModel.notes.addTextToNote(selectedText, pageIndex: nil, source: "Web Page")
        viewModel.state.rightPanelMode = .notes
        dismiss()
    }

    private func translateText() {
        viewModel.translation.setSourceText(selectedText)
        viewModel.state.rightPanelMode = .translation
        dismiss()
    }

    private func generateQuiz() {
        guard !selectedText.isEmpty, selectedText.count >= 10 else { return }

        // Apply purple highlight in the web view
        if let webView {
            let purpleCss = "rgba(163,138,230,0.35)"
            webView.evaluateJavaScript(
                "OakHighlighter.highlightSelection('\(purpleCss)', 'highlight');",
                completionHandler: nil
            )
        }

        let documentTitle = viewModel.libraryItem?.title ?? viewModel.fileName
        let itemId = viewModel.itemId ?? ""

        dismiss()

        // Kick off background generation (no annotation ID for web — uses a synthetic one)
        guard let database = viewModel.database, !itemId.isEmpty else { return }
        let service = QuizGenerationService(database: database)
        let annotationId = UUID().uuidString
        let text = selectedText

        Task {
            do {
                let cards = try await service.generateFromHighlight(
                    sourceText: text,
                    pageContext: text, // For HTML, source text is the primary context
                    documentTitle: documentTitle,
                    itemId: itemId,
                    annotationId: annotationId
                )
                await MainActor.run {
                    viewModel.appState?.importNotification = "Generated \(cards.count) quiz card\(cards.count == 1 ? "" : "s")"
                    viewModel.quizCards.loadCards()
                }
            } catch {
                Log.error(Log.store, "Quiz generation failed: \(error)")
                await MainActor.run {
                    viewModel.appState?.importNotification = "Quiz generation failed"
                }
            }
        }
    }

    private func speakSelection() {
        let voice = viewModel.voice
        if voice.isSpeaking {
            voice.stopSpeaking()
            speakButton?.updateImage(systemImage: "speaker.wave.2")
            return
        }

        guard !selectedText.isEmpty else { return }
        voice.speakText(selectedText)
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

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
        dismiss()
    }

    func dismiss() {
        removeAppResignObserver()

        // Stop TTS playback if active
        viewModel.voice.stopSpeaking()

        colorSubPanel?.orderOut(nil)
        colorSubPanel = nil

        let callback = onDismiss
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            if HTMLSelectionPopupPanel.current === self {
                HTMLSelectionPopupPanel.current = nil
            }
            callback()
        })
    }
}

// MARK: - Web Area Selection Popup Panel

/// Popup for area captures in the HTML document viewer.
/// Offers "Add to Chat" and "Copy Image".
class WebAreaPopupPanel: NSPanel, AppResignDismissable {
    private static var current: WebAreaPopupPanel?

    private let viewModel: DocumentViewModel
    private let imageData: Data
    private let onDismiss: () -> Void
    var resignObserver: NSObjectProtocol?

    static func show(
        at screenPoint: NSPoint,
        imageData: Data,
        viewModel: DocumentViewModel,
        onDismiss: @escaping () -> Void
    ) {
        current?.dismiss()

        let panel = WebAreaPopupPanel(
            at: screenPoint,
            imageData: imageData,
            viewModel: viewModel,
            onDismiss: onDismiss
        )
        current = panel
    }

    static func dismissCurrent() {
        current?.dismiss()
    }

    private init(
        at screenPoint: NSPoint,
        imageData: Data,
        viewModel: DocumentViewModel,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.imageData = imageData
        self.onDismiss = onDismiss

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        ignoresMouseEvents = false
        appearance = NSAppearance(named: .aqua)

        let content = buildContentView()
        self.contentView = content

        let contentSize = content.fittingSize
        setContentSize(contentSize)

        // Position: centered below selection
        let x = screenPoint.x - contentSize.width / 2
        let y = screenPoint.y - contentSize.height - 8
        setFrameOrigin(NSPoint(x: x, y: y))

        orderFront(nil)

        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 1
        }

        observeAppResign()
    }

    private func buildContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        // Add to Chat
        let chatBtn = PopupActionButton(
            systemImage: "bubble.left",
            title: "Add to Chat"
        ) { [weak self] in
            self?.addToChat()
        }
        stack.addArrangedSubview(chatBtn)
        chatBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        chatBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Add to Note
        if Preferences.shared.isExtensionEnabled(.notes) {
            let noteBtn = PopupActionButton(
                systemImage: "note.text.badge.plus",
                title: "Add to Note"
            ) { [weak self] in
                self?.addToNote()
            }
            stack.addArrangedSubview(noteBtn)
            noteBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
            noteBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true
        }

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)

        // Copy Image
        let copyBtn = PopupActionButton(
            systemImage: "doc.on.doc",
            title: "Copy Image"
        ) { [weak self] in
            self?.copyImage()
        }
        stack.addArrangedSubview(copyBtn)
        copyBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        copyBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Background
        let container = makePopupGlassContainer(content: stack, cornerRadius: 6)

        // Match PDF popup width
        container.widthAnchor.constraint(equalToConstant: 246).isActive = true

        return container
    }

    private func addToChat() {
        viewModel.chat.addImageAttachment(imageData, pageIndex: 0)
        viewModel.state.rightPanelMode = .aiChat
        dismiss()
    }

    private func addToNote() {
        viewModel.notes.addImageToNote(imageData, pageIndex: nil, source: "Web Page")
        viewModel.state.rightPanelMode = .notes
        dismiss()
    }

    private func copyImage() {
        guard let nsImage = NSImage(data: imageData) else {
            dismiss()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
        dismiss()
        showCopiedToast()
    }

    private func showCopiedToast() {
        guard let window = NSApp.keyWindow else { return }

        let toast = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.level = .floating
        toast.ignoresMouseEvents = true

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 180, height: 36))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8

        let icon = NSImageView(frame: NSRect(x: 12, y: 6, width: 24, height: 24))
        if let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            icon.image = img.withSymbolConfiguration(config)
            icon.contentTintColor = .systemGreen
        }
        bg.addSubview(icon)

        let label = NSTextField(labelWithString: "Copied to clipboard")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 40, y: 8, width: 130, height: 20)
        bg.addSubview(label)

        toast.contentView = bg

        let windowFrame = window.frame
        let toastX = windowFrame.midX - 90
        let toastY = windowFrame.midY - 18
        toast.setFrameOrigin(NSPoint(x: toastX, y: toastY))
        toast.orderFront(nil)

        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            toast.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                toast.animator().alphaValue = 0
            }, completionHandler: {
                toast.orderOut(nil)
            })
        }
    }

    func dismiss() {
        removeAppResignObserver()

        let callback = onDismiss
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            if WebAreaPopupPanel.current === self {
                WebAreaPopupPanel.current = nil
            }
            callback()
        })
    }
}
