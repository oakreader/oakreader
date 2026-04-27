import AppKit

// MARK: - Web Text Selection Popup Panel

/// Lightweight popup for text selected in the web snapshot viewer.
/// Offers "Add to Chat" and "Copy" — no PDF annotation features.
class WebSelectionPopupPanel: NSPanel {
    private static var current: WebSelectionPopupPanel?

    private let viewModel: DocumentViewModel
    private let selectedText: String
    private let onDismiss: () -> Void

    static func show(
        at screenPoint: NSPoint,
        text: String,
        viewModel: DocumentViewModel,
        onDismiss: @escaping () -> Void
    ) {
        current?.dismiss()

        let panel = WebSelectionPopupPanel(
            at: screenPoint,
            text: text,
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
        text: String,
        viewModel: DocumentViewModel,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.selectedText = text
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
        let y = screenPoint.y - contentSize.height - 6
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

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)

        // Copy
        let copyBtn = PopupActionButton(
            systemImage: "doc.on.doc",
            title: "Copy"
        ) { [weak self] in
            self?.copyText()
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

        // Match PDF popup width (8 color dots × 20 + 7 gaps × 10 + padding)
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
        viewModel.chat.addTextAttachment(selectedText, pageIndex: 0)
        viewModel.state.rightPanelMode = .aiChat
        dismiss()
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
        dismiss()
    }

    func dismiss() {
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
