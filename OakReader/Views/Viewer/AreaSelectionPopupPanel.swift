import AppKit
import PDFKit

// MARK: - Area Selection Popup

class AreaSelectionPopupPanel: NSPanel, AppResignDismissable {
    private static var current: AreaSelectionPopupPanel?

    private let viewModel: DocumentViewModel
    private let pdfRect: CGRect
    private let page: PDFPage
    private let pageIndex: Int
    private let annotationColor: NSColor
    private let onDismiss: (() -> Void)?

    // Color sub-panel
    private var colorSubPanel: NSPanel?
    var resignObserver: NSObjectProtocol?

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

    /// Returns true if the given window belongs to this popup or its color sub-panel.
    func ownsWindow(_ window: NSWindow) -> Bool {
        return window === self || window === colorSubPanel
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

        observeAppResign()
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

    // MARK: - Content View (horizontal toolbar)

    private func buildContentView() -> NSView {
        // Same Marshall-lifecycle grouping as TextSelectionPopupPanel.
        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.spacing = 4
        mainStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        mainStack.alignment = .centerY

        // Group 1: Area annotation split button
        let areaSplit = AreaSplitButton(color: annotationColor) { [weak self] in
            guard let self else { return }
            self.addAreaAnnotation(color: self.annotationColor)
        } onChevronClick: { [weak self] in
            self?.toggleColorSubPanel()
        }
        mainStack.addArrangedSubview(areaSplit)

        // Separator 1
        mainStack.addArrangedSubview(makeVerticalSeparator())

        // Group 2: Actions (chat)
        let chatBtn = PopupIconButton(
            systemImage: "text.quote",
            accessibilityLabel: "Add to Chat"
        ) { [weak self] in
            self?.addToChat()
        }
        mainStack.addArrangedSubview(chatBtn)

        // Separator 2
        mainStack.addArrangedSubview(makeVerticalSeparator())

        // Group 3: Clipboard (copy image)
        let copyBtn = PopupIconButton(
            systemImage: "doc.on.doc",
            accessibilityLabel: "Copy Image"
        ) { [weak self] in
            self?.copyImage()
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
            wrapper.widthAnchor.constraint(equalToConstant: 11),
            wrapper.heightAnchor.constraint(equalToConstant: 22),
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
                self?.addAreaAnnotation(color: color)
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

        // Position below the main toolbar, left-aligned with split button
        let splitOffset: CGFloat = 6 // matches mainStack leading edge inset
        let x = mainFrame.origin.x + splitOffset
        let y = mainFrame.origin.y - panelSize.height - 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Actions

    private func addToChat() {
        guard let pngData = renderAreaAsPNG() else {
            dismiss()
            return
        }
        viewModel.chat.addImageAttachment(pngData, pageIndex: pageIndex)
        viewModel.state.rightPanelMode = .aiChat
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
        viewModel.annotation.addAreaAnnotation(bounds: pdfRect, page: page, pageIndex: pageIndex, color: color)
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
        removeAppResignObserver()

        colorSubPanel?.orderOut(nil)
        colorSubPanel = nil

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

// MARK: - Area Split Button (rectangle.dashed icon + color bar + chevron)

private class AreaSplitButton: NSView {
    private var currentColor: NSColor
    private let onAreaClick: () -> Void
    private let onChevronClick: () -> Void

    private var iconHovered = false
    private var chevronHovered = false
    private var trackingArea: NSTrackingArea?
    private let colorBar = NSView()
    private let iconView = NSImageView()
    private let chevronView = NSImageView()

    private let iconWidth: CGFloat = 28
    private let chevronWidth: CGFloat = 16
    private let totalHeight: CGFloat = 32

    init(color: NSColor, onAreaClick: @escaping () -> Void, onChevronClick: @escaping () -> Void) {
        self.currentColor = color
        self.onAreaClick = onAreaClick
        self.onChevronClick = onChevronClick
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 32))

        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: iconWidth + chevronWidth),
            heightAnchor.constraint(equalToConstant: totalHeight),
        ])

        setupIcon()
        setupChevron()
        setupColorBar()

        toolTip = "Area Annotation"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupIcon() {
        if let img = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Area Annotation") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func setupChevron() {
        if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Color picker") {
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            chevronView.image = img.withSymbolConfiguration(config)
        }
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronView)
        NSLayoutConstraint.activate([
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    private func setupColorBar() {
        colorBar.wantsLayer = true
        colorBar.layer?.backgroundColor = currentColor.cgColor
        colorBar.layer?.cornerRadius = 1.5
        colorBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(colorBar)
        NSLayoutConstraint.activate([
            colorBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            colorBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            colorBar.widthAnchor.constraint(equalToConstant: 18),
            colorBar.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    private func isInIconRegion(_ point: NSPoint) -> Bool {
        return point.x < iconWidth
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let wasIconHovered = iconHovered
        let wasChevronHovered = chevronHovered

        iconHovered = bounds.contains(pt) && isInIconRegion(pt)
        chevronHovered = bounds.contains(pt) && !isInIconRegion(pt)

        if iconHovered != wasIconHovered || chevronHovered != wasChevronHovered {
            updateAppearance()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        iconHovered = isInIconRegion(pt)
        chevronHovered = !isInIconRegion(pt)
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        iconHovered = false
        chevronHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else {
            updateAppearance()
            return
        }

        if isInIconRegion(pt) {
            onAreaClick()
        } else {
            onChevronClick()
        }
        updateAppearance()
    }

    private func updateAppearance() {
        if iconHovered || chevronHovered {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            iconView.contentTintColor = .labelColor
            chevronView.contentTintColor = .secondaryLabelColor
        } else {
            layer?.backgroundColor = nil
            iconView.contentTintColor = .secondaryLabelColor
            chevronView.contentTintColor = .tertiaryLabelColor
        }
    }
}
