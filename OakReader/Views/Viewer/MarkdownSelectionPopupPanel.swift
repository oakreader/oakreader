import AppKit
import OakReaderAI

// MARK: - Markdown Text Selection Popup Panel

/// Horizontal toolbar popup for text selected in the Markdown editor.
/// Offers AI writing tools (Improve Writing, Fix Grammar), Translate, Speak, Copy,
/// with inline diff display and Accept/Reject flow.
class MarkdownSelectionPopupPanel: NSPanel {
    private(set) static var current: MarkdownSelectionPopupPanel?

    private let viewModel: DocumentViewModel?
    private let selectedText: String
    private let selectedRange: NSRange
    private weak var textView: MarkdownNSTextView?

    // AI state
    private var streamTask: Task<Void, Never>?
    private let router = ProviderRouter()
    private var isDiffShowing = false

    // UI references for mode switching
    private var mainStack: NSStackView!
    private var actionViews: [NSView] = []
    private var diffViews: [NSView] = []
    private weak var speakButton: PopupIconButton?
    private weak var improveButton: PopupLabeledButton?
    private weak var grammarButton: PopupLabeledButton?
    private weak var activeLoadingButton: PopupLabeledButton?

    // Mouse monitor
    private var mouseMonitor: Any?

    static func show(
        at screenPoint: NSPoint,
        text: String,
        range: NSRange,
        textView: MarkdownNSTextView,
        viewModel: DocumentViewModel? = nil
    ) {
        current?.dismiss()

        let panel = MarkdownSelectionPopupPanel(
            at: screenPoint,
            text: text,
            range: range,
            textView: textView,
            viewModel: viewModel
        )
        current = panel
    }

    static func dismissCurrent() {
        current?.dismiss()
    }

    private init(
        at screenPoint: NSPoint,
        text: String,
        range: NSRange,
        textView: MarkdownNSTextView,
        viewModel: DocumentViewModel?
    ) {
        self.viewModel = viewModel
        self.selectedText = text
        self.selectedRange = range
        self.textView = textView

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

        let content = buildContentView()
        self.contentView = content

        let contentSize = content.fittingSize
        setContentSize(contentSize)

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

        setFrameOrigin(NSPoint(x: x, y: y))
        orderFront(nil)

        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 1
        }

        installMouseMonitor()
    }

    // MARK: - Content View

    private func buildContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.alignment = .centerY
        self.mainStack = stack

        // --- Action buttons (shown initially) ---

        // Group 1: AI writing tools (labeled buttons)
        let improveBtn = PopupLabeledButton(
            systemImage: "wand.and.stars",
            title: "Improve"
        ) { [weak self] in
            self?.runAIAction(mode: .improveWriting)
        }
        self.improveButton = improveBtn
        stack.addArrangedSubview(improveBtn)
        actionViews.append(improveBtn)

        let grammarBtn = PopupLabeledButton(
            systemImage: "textformat.abc",
            title: "Grammar"
        ) { [weak self] in
            self?.runAIAction(mode: .fixGrammar)
        }
        self.grammarButton = grammarBtn
        stack.addArrangedSubview(grammarBtn)
        actionViews.append(grammarBtn)

        // Separator 1
        let sep1 = makeVerticalSeparator()
        stack.addArrangedSubview(sep1)
        actionViews.append(sep1)

        // Group 2: Translate + Speak (only when DocumentViewModel is available)
        if viewModel != nil, Preferences.shared.isPluginEnabled(.translation) {
            let translateBtn = PopupIconButton(
                systemImage: "character.bubble",
                accessibilityLabel: "Translate"
            ) { [weak self] in
                self?.translateText()
            }
            stack.addArrangedSubview(translateBtn)
            actionViews.append(translateBtn)
        }

        if viewModel != nil {
            let speakBtn = PopupIconButton(
                systemImage: "speaker.wave.2",
                accessibilityLabel: "Play Sound"
            ) { [weak self] in
                self?.speakText()
            }
            self.speakButton = speakBtn
            stack.addArrangedSubview(speakBtn)
            actionViews.append(speakBtn)
        }

        // Separator 2
        let sep2 = makeVerticalSeparator()
        stack.addArrangedSubview(sep2)
        actionViews.append(sep2)

        // Group 3: Copy
        let copyBtn = PopupIconButton(
            systemImage: "doc.on.doc",
            accessibilityLabel: "Copy"
        ) { [weak self] in
            self?.copyText()
        }
        stack.addArrangedSubview(copyBtn)
        actionViews.append(copyBtn)

        // --- Diff buttons (hidden initially, shown after AI completes) ---

        let acceptBtn = PopupLabeledButton(
            systemImage: "checkmark",
            title: "Accept"
        ) { [weak self] in
            self?.acceptDiff()
        }
        stack.addArrangedSubview(acceptBtn)
        diffViews.append(acceptBtn)

        let rejectBtn = PopupLabeledButton(
            systemImage: "xmark",
            title: "Reject"
        ) { [weak self] in
            self?.rejectDiff()
        }
        stack.addArrangedSubview(rejectBtn)
        diffViews.append(rejectBtn)

        // Hide diff views initially
        for view in diffViews {
            view.isHidden = true
        }

        // Background container
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return container
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

    // MARK: - Mode Switching

    private func switchToDiffMode() {
        activeLoadingButton?.hideLoading()
        activeLoadingButton = nil

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true

            for view in actionViews { view.isHidden = true }
            for view in diffViews { view.isHidden = false }

            resizeToFit()
        }
    }

    private func resizeToFit() {
        guard let content = contentView else { return }
        let newSize = content.fittingSize
        let oldFrame = frame
        // Keep centered horizontally relative to old position
        let newX = oldFrame.midX - newSize.width / 2
        let newY = oldFrame.origin.y + (oldFrame.height - newSize.height)
        setFrame(NSRect(x: newX, y: newY, width: newSize.width, height: newSize.height), display: true)
    }

    // MARK: - AI Actions

    private enum AIMode {
        case improveWriting
        case fixGrammar
    }

    private func runAIAction(mode: AIMode) {
        // Show loading spinner on the clicked button
        let btn: PopupLabeledButton? = mode == .improveWriting ? improveButton : grammarButton
        btn?.showLoading()
        activeLoadingButton = btn

        let prefs = Preferences.shared
        let pid = prefs.translationAIProviderId
        let model: String = {
            let m = prefs.translationAIModel
            return m.isEmpty ? (ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? "") : m
        }()

        let systemPrompt: String
        let userPrompt: String

        switch mode {
        case .improveWriting:
            systemPrompt = "You are a writing assistant. Improve the given text for clarity, conciseness, and readability while preserving the original meaning and tone. Output ONLY the improved text, nothing else."
            userPrompt = "Improve the following text:\n\n\(selectedText)"
        case .fixGrammar:
            systemPrompt = "You are a grammar correction engine. Fix all grammar, spelling, and punctuation errors in the given text. Output ONLY the corrected text, nothing else."
            userPrompt = "Fix the grammar in the following text:\n\n\(selectedText)"
        }

        let config = ProviderConfig(providerId: pid, model: model)
        let messages = [LLMMessage(role: .user, text: userPrompt)]

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var result = ""

            do {
                let svc = try self.router.provider(for: config)
                let stream = svc.sendMessage(
                    messages: messages,
                    model: model,
                    systemPrompt: systemPrompt,
                    maxTokens: 4096
                )

                for try await chunk in stream {
                    switch chunk {
                    case .delta(let delta):
                        result += delta
                    case .toolUse:
                        break
                    case .finished:
                        break
                    case .error(let msg):
                        self.handleAIError(msg)
                        return
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    self.handleAIError(error.localizedDescription)
                }
                return
            }

            // Apply inline diff
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let tv = self.textView else {
                self.dismiss()
                return
            }

            tv.showInlineDiff(originalRange: self.selectedRange, newText: trimmed)

            // If diff was skipped (identical text), dismiss
            guard tv.diffState != nil else {
                self.dismiss()
                return
            }

            self.isDiffShowing = true
            self.switchToDiffMode()
        }
    }

    private func handleAIError(_ message: String) {
        // On error, dismiss and restore normal state
        dismiss()
    }

    // MARK: - Diff Accept / Reject

    private func acceptDiff() {
        textView?.acceptDiff()
        isDiffShowing = false
        dismiss()
    }

    private func rejectDiff() {
        textView?.rejectDiff()
        isDiffShowing = false
        dismiss()
    }

    // MARK: - Other Actions

    private func translateText() {
        guard let viewModel else { return }
        viewModel.translation.setSourceText(selectedText)
        viewModel.state.rightPanelMode = .translation
        dismiss()
    }

    private func speakText() {
        guard let viewModel else { return }
        let voice = viewModel.voice
        if voice.isSpeaking {
            voice.stopSpeaking()
            speakButton?.updateImage(systemImage: "speaker.wave.2")
            return
        }

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
                if self.viewModel?.voice.isSpeaking == true {
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

    // MARK: - Mouse Monitor

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let eventWindow = event.window, eventWindow === self {
                return event
            }
            self.dismiss()
            return event
        }
    }

    // MARK: - Dismiss

    func dismiss() {
        // Cancel AI stream
        streamTask?.cancel()
        streamTask = nil

        // Stop loading spinner on button
        activeLoadingButton?.hideLoading()
        activeLoadingButton = nil

        // Reject diff if showing
        if isDiffShowing {
            textView?.rejectDiff()
            isDiffShowing = false
        }

        // Stop TTS
        viewModel?.voice.stopSpeaking()

        // Remove mouse monitor
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            if MarkdownSelectionPopupPanel.current === self {
                MarkdownSelectionPopupPanel.current = nil
            }
        })
    }
}
