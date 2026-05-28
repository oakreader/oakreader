import AppKit

/// Floating glass popup for text selected in the Milkdown note editor.
/// Matches the app's HTML/PDF selection popups (`makePopupGlassContainer` +
/// `PopupIconButton`), but its actions suit an editor: AI润色 / Fix Grammar
/// (which run Crepe's AI + diff-review via the editor bridge), Translate, Speak,
/// Copy. Crepe's own selection toolbar is disabled so this is the only one.
final class NoteSelectionPopupPanel: NSPanel, AppResignDismissable {
    private(set) static var current: NoteSelectionPopupPanel?

    private let selectedText: String
    private let runAI: (String) -> Void
    private weak var viewModel: DocumentViewModel?
    private let onDismiss: () -> Void
    private weak var speakButton: PopupIconButton?
    private var mouseMonitor: Any?
    var resignObserver: NSObjectProtocol?

    static func show(
        atTop topScreenPoint: NSPoint,
        atBottom bottomScreenPoint: NSPoint,
        text: String,
        runAI: @escaping (String) -> Void,
        viewModel: DocumentViewModel?,
        onDismiss: @escaping () -> Void
    ) {
        current?.dismiss()
        current = NoteSelectionPopupPanel(
            atTop: topScreenPoint, atBottom: bottomScreenPoint,
            text: text, runAI: runAI, viewModel: viewModel, onDismiss: onDismiss
        )
    }

    static func dismissCurrent() { current?.dismiss() }

    private init(
        atTop topScreenPoint: NSPoint,
        atBottom bottomScreenPoint: NSPoint,
        text: String,
        runAI: @escaping (String) -> Void,
        viewModel: DocumentViewModel?,
        onDismiss: @escaping () -> Void
    ) {
        self.selectedText = text
        self.runAI = runAI
        self.viewModel = viewModel
        self.onDismiss = onDismiss

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        ignoresMouseEvents = false
        appearance = NSAppearance(named: .aqua)

        let content = buildContentView()
        contentView = content
        let size = content.fittingSize
        setContentSize(size)

        // Centered above the selection top; flip below on screen overflow.
        let x = topScreenPoint.x - size.width / 2
        var y = topScreenPoint.y + 6
        if let screen = NSScreen.main, y + size.height > screen.visibleFrame.maxY {
            y = bottomScreenPoint.y - size.height - 6
        }
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFront(nil)

        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }

        installMouseMonitor()
        observeAppResign()
    }

    private func buildContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.alignment = .centerY

        // Group 1: AI
        stack.addArrangedSubview(PopupIconButton(systemImage: "wand.and.stars", accessibilityLabel: "AI 润色") { [weak self] in
            self?.runAIAction("Improve writing")
        })
        stack.addArrangedSubview(PopupIconButton(systemImage: "text.badge.checkmark", accessibilityLabel: "修正语法") { [weak self] in
            self?.runAIAction("Fix spelling and grammar")
        })

        stack.addArrangedSubview(makeVerticalSeparator())

        // Group 2: actions
        if Preferences.shared.isExtensionEnabled(.translation) {
            stack.addArrangedSubview(PopupIconButton(systemImage: "translate", accessibilityLabel: "翻译") { [weak self] in
                self?.translate()
            })
        }
        let speak = PopupIconButton(systemImage: "speaker.wave.2", accessibilityLabel: "朗读") { [weak self] in
            self?.toggleSpeak()
        }
        speakButton = speak
        stack.addArrangedSubview(speak)

        stack.addArrangedSubview(makeVerticalSeparator())

        // Group 3: clipboard
        stack.addArrangedSubview(PopupIconButton(systemImage: "doc.on.doc", accessibilityLabel: "复制") { [weak self] in
            self?.copy()
        })

        return makePopupGlassContainer(content: stack)
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

    // MARK: - Actions

    private func runAIAction(_ instruction: String) {
        runAI(instruction) // editor runs Crepe's RunAI + diff-review on the selection
        dismiss()
    }

    private func translate() {
        viewModel?.translation.setSourceText(selectedText)
        viewModel?.state.rightPanelMode = .translation
        dismiss()
    }

    private func toggleSpeak() {
        guard let voice = viewModel?.voice else { return }
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
        guard let viewModel else { return }
        withObservationTracking {
            _ = viewModel.voice.isSpeaking
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if viewModel.voice.isSpeaking {
                    self.observeSpeakingState()
                } else {
                    self.speakButton?.updateImage(systemImage: "speaker.wave.2")
                }
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
        dismiss()
    }

    // MARK: - Dismiss

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let w = event.window, w === self { return event }
            self.dismiss()
            return event
        }
    }

    func dismiss() {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor); mouseMonitor = nil }
        removeAppResignObserver()
        viewModel?.voice.stopSpeaking()

        let callback = onDismiss
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            if NoteSelectionPopupPanel.current === self { NoteSelectionPopupPanel.current = nil }
            callback()
        })
    }
}
