import AppKit
import PDFKit

// MARK: - Area Selection Popup

class AreaSelectionPopupPanel: NSPanel {
    private static var current: AreaSelectionPopupPanel?

    private let viewModel: DocumentViewModel
    private let pdfRect: CGRect
    private let page: PDFPage
    private let pageIndex: Int
    private let annotationColor: NSColor
    private let onDismiss: (() -> Void)?

    static func show(
        at screenPoint: NSPoint,
        pdfRect: CGRect,
        page: PDFPage,
        pageIndex: Int,
        viewModel: DocumentViewModel,
        annotationColor: NSColor,
        onDismiss: (() -> Void)? = nil
    ) {
        current?.dismiss()

        let panel = AreaSelectionPopupPanel(
            at: screenPoint,
            pdfRect: pdfRect,
            page: page,
            pageIndex: pageIndex,
            viewModel: viewModel,
            annotationColor: annotationColor,
            onDismiss: onDismiss
        )
        current = panel
    }

    private init(
        at screenPoint: NSPoint,
        pdfRect: CGRect,
        page: PDFPage,
        pageIndex: Int,
        viewModel: DocumentViewModel,
        annotationColor: NSColor,
        onDismiss: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.pdfRect = pdfRect
        self.page = page
        self.pageIndex = pageIndex
        self.annotationColor = annotationColor
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

        // Position: centered below the selection
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

    private static let annotationColors: [(NSColor, String)] = [
        (NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0), "Yellow"),      // #ffd400
        (NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0), "Red"),           // #ff6666
        (NSColor(red: 0.37, green: 0.70, blue: 0.21, alpha: 1.0), "Green"),      // #5fb236
        (NSColor(red: 0.18, green: 0.66, blue: 0.90, alpha: 1.0), "Blue"),       // #2ea8e5
        (NSColor(red: 0.64, green: 0.54, blue: 0.90, alpha: 1.0), "Purple"),     // #a28ae5
        (NSColor(red: 0.90, green: 0.43, blue: 0.93, alpha: 1.0), "Magenta"),    // #e56eee
        (NSColor(red: 0.95, green: 0.60, blue: 0.22, alpha: 1.0), "Orange"),     // #f19837
        (NSColor(red: 0.67, green: 0.67, blue: 0.67, alpha: 1.0), "Gray"),       // #aaaaaa
    ]

    private func buildContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        // Row 1: Color dots — click to instantly add area annotation in that color
        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 10
        colorRow.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        for (color, name) in Self.annotationColors {
            let dot = AreaColorDotView(color: color, size: 20) { [weak self] in
                self?.addAreaAnnotation(color: color)
            }
            dot.toolTip = name
            colorRow.addArrangedSubview(dot)
        }
        stack.addArrangedSubview(colorRow)

        // Separator
        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep1)

        // Row 2: Add to Chat (full width)
        let chatBtn = AreaPopupActionButton(
            systemImage: "bubble.left",
            title: "Add to Chat"
        ) { [weak self] in
            self?.addToChat()
        }
        stack.addArrangedSubview(chatBtn)
        chatBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        chatBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Row 3: Add to Note (full width)
        let noteBtn = AreaPopupActionButton(
            systemImage: "note.text.badge.plus",
            title: "Add to Note"
        ) { [weak self] in
            self?.addToNote()
        }
        stack.addArrangedSubview(noteBtn)
        noteBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        noteBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep2)

        // Row 4: Copy Image (full width)
        let copyBtn = AreaPopupActionButton(
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
        guard let pngData = renderAreaAsPNG() else {
            dismiss()
            return
        }
        viewModel.chat.addImageAttachment(pngData, pageIndex: pageIndex)
        viewModel.state.rightPanelMode = .aiChat
        dismiss()
    }

    private func addToNote() {
        guard let pngData = renderAreaAsPNG() else {
            dismiss()
            return
        }
        viewModel.notes.addImageToNote(pngData, pageIndex: pageIndex, source: "PDF")
        viewModel.state.rightPanelMode = .notes
        dismiss()
    }

    private func renderAreaAsPNG() -> Data? {
        let renderService = PDFRenderingService()
        guard let cgImage = renderService.renderPageRegion(page, region: pdfRect, dpi: 300) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return pngData
    }

    private func copyImage() {
        guard let pngData = renderAreaAsPNG(),
              let nsImage = NSImage(data: pngData) else {
            dismiss()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])

        dismiss()
        showCopiedToast()
    }

    private func addAreaAnnotation(color: NSColor) {
        // Create a square (rectangle) annotation with colored border, no fill — like OakReader
        let annotation = PDFAnnotation.rectangle(
            bounds: pdfRect,
            color: color,
            fillColor: nil,
            lineWidth: 3.0
        )
        page.addAnnotation(annotation)
        viewModel.markDocumentEdited()
        viewModel.annotation.refreshAnnotationModels()
        dismiss()
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
            if AreaSelectionPopupPanel.current === self {
                AreaSelectionPopupPanel.current = nil
            }
            callback?()
        })
    }
}

// MARK: - Color Dot (OakReader-style round swatch for area popup)

private class AreaColorDotView: NSView {
    private let color: NSColor
    private let onClick: () -> Void
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(color: NSColor, size: CGFloat, onClick: @escaping () -> Void) {
        self.color = color
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isHovered ? 0.5 : 1.0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()

        if isHovered {
            NSColor.controlTextColor.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // visual feedback
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onClick()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}

// MARK: - Popup Action Button for Area Popup (icon + label, OakReader-style)

private class AreaPopupActionButton: NSButton {
    private let onClick: () -> Void

    init(systemImage: String, title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)

        self.title = title
        isBordered = true
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = NSFont.systemFont(ofSize: 11, weight: .regular)
        contentTintColor = .labelColor

        if let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            self.image = img.withSymbolConfiguration(config)
        }
        imagePosition = .imageLeading
        imageHugsTitle = true

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick() }
}
