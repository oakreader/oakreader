import AppKit
import WebKit

// MARK: - Web Text Selection Popup Panel

/// Horizontal toolbar popup for text selected in web snapshot viewers.
/// Matches the PDF text selection popup style with highlight, chat, note, translate, copy.
class WebSelectionPopupPanel: NSPanel {
    private(set) static var current: WebSelectionPopupPanel?

    private let viewModel: DocumentViewModel
    private let selectedText: String
    private weak var webView: WKWebView?
    private let onDismiss: () -> Void

    // Color sub-panel
    private var colorSubPanel: NSPanel?

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
        at screenPoint: NSPoint,
        text: String,
        viewModel: DocumentViewModel,
        webView: WKWebView?,
        onDismiss: @escaping () -> Void
    ) {
        current?.dismiss()

        let panel = WebSelectionPopupPanel(
            at: screenPoint,
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

    private init(
        at screenPoint: NSPoint,
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

        let content = buildContentView()
        self.contentView = content

        let contentSize = content.fittingSize
        setContentSize(contentSize)

        // Position: centered above selection (matching PDF popup)
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
    }

    // MARK: - Content View (horizontal toolbar)

    private func buildContentView() -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.spacing = 2
        mainStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        mainStack.alignment = .centerY

        // Group 1: Highlight
        let highlightBtn = PopupIconButton(
            systemImage: "highlighter",
            accessibilityLabel: "Highlight"
        ) { [weak self] in
            self?.applyHighlight(colorIndex: 0) // default yellow
        }
        mainStack.addArrangedSubview(highlightBtn)

        let colorChevron = PopupIconButton(
            systemImage: "chevron.down",
            accessibilityLabel: "Highlight Color"
        ) { [weak self] in
            self?.toggleColorSubPanel()
        }
        // Make chevron smaller
        colorChevron.removeConstraints(colorChevron.constraints)
        colorChevron.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            colorChevron.widthAnchor.constraint(equalToConstant: 20),
            colorChevron.heightAnchor.constraint(equalToConstant: 32),
        ])
        mainStack.addArrangedSubview(colorChevron)

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

        if Preferences.shared.isPluginEnabled(.notes) {
            let noteBtn = PopupIconButton(
                systemImage: "note.text.badge.plus",
                accessibilityLabel: "Add to Note"
            ) { [weak self] in
                self?.addToNote()
            }
            mainStack.addArrangedSubview(noteBtn)
        }

        if Preferences.shared.isPluginEnabled(.translation) {
            let translateBtn = PopupIconButton(
                systemImage: "translate",
                accessibilityLabel: "Translate"
            ) { [weak self] in
                self?.translateText()
            }
            mainStack.addArrangedSubview(translateBtn)
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
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        container.addSubview(mainStack)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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
        colorStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        for (index, (color, name, _)) in Self.highlightColors.enumerated() {
            let dot = ColorDotView(color: color, size: 14) { [weak self] in
                self?.applyHighlight(colorIndex: index)
            }
            dot.toolTip = name
            colorStack.addArrangedSubview(dot)
        }

        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        container.addSubview(colorStack)
        colorStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            colorStack.topAnchor.constraint(equalTo: container.topAnchor),
            colorStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            colorStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            colorStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

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
        let js = """
        (function() {
            var sel = window.getSelection();
            if (!sel.rangeCount || sel.isCollapsed) return;
            var range = sel.getRangeAt(0);
            var contents = range.extractContents();
            var mark = document.createElement('mark');
            mark.className = 'oak-highlight';
            mark.style.backgroundColor = '\(cssColor)';
            mark.style.borderRadius = '2px';
            mark.style.padding = '1px 0';
            mark.appendChild(contents);
            range.insertNode(mark);
            sel.removeAllRanges();
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        dismiss()
    }

    private func addToChat() {
        viewModel.chat.addTextAttachment(selectedText, pageIndex: 0)
        viewModel.state.rightPanelMode = .aiChat
        dismiss()
    }

    private func addToNote() {
        viewModel.notes.addTextToNote(selectedText, pageIndex: nil, source: "Web Snapshot")
        viewModel.state.rightPanelMode = .notes
        dismiss()
    }

    private func translateText() {
        viewModel.translation.setSourceText(selectedText)
        viewModel.state.rightPanelMode = .translation
        dismiss()
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
        dismiss()
    }

    func dismiss() {
        colorSubPanel?.orderOut(nil)
        colorSubPanel = nil

        let callback = onDismiss
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            if WebSelectionPopupPanel.current === self {
                WebSelectionPopupPanel.current = nil
            }
            callback()
        })
    }
}

// MARK: - Web Area Selection Popup Panel

/// Popup for area captures in the web snapshot viewer.
/// Offers "Add to Chat" and "Copy Image".
class WebAreaPopupPanel: NSPanel {
    private static var current: WebAreaPopupPanel?

    private let viewModel: DocumentViewModel
    private let imageData: Data
    private let onDismiss: () -> Void

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
        if Preferences.shared.isPluginEnabled(.notes) {
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
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 6

        // Match PDF popup width
        container.widthAnchor.constraint(equalToConstant: 246).isActive = true

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

    private func addToChat() {
        viewModel.chat.addImageAttachment(imageData, pageIndex: 0)
        viewModel.state.rightPanelMode = .aiChat
        dismiss()
    }

    private func addToNote() {
        viewModel.notes.addImageToNote(imageData, pageIndex: nil, source: "Web Snapshot")
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
