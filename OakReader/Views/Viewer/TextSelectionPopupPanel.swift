import Foundation
import PDFKit
import AppKit

// MARK: - Text Selection Popup Panel (horizontal toolbar above selection)

class TextSelectionPopupPanel: NSPanel {
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

    // Color sub-panel
    private var colorSubPanel: NSPanel?
    private weak var splitButton: HighlightSplitButton?

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
        mainStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        mainStack.alignment = .centerY

        // Group 1: Markup (highlight split + underline)
        let currentColor = viewModel.annotation.strokeColor
            ?? NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0)
        let highlightSplit = HighlightSplitButton(color: currentColor) { [weak self] in
            self?.applyHighlight(
                color: self?.viewModel.annotation.strokeColor
                    ?? NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0)
            )
        } onChevronClick: { [weak self] in
            self?.toggleColorSubPanel()
        }
        self.splitButton = highlightSplit

        let underlineBtn = PopupIconButton(
            systemImage: "underline",
            accessibilityLabel: "Underline"
        ) { [weak self] in
            self?.applyUnderline()
        }

        mainStack.addArrangedSubview(highlightSplit)
        mainStack.addArrangedSubview(underlineBtn)

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
                systemImage: "character.book.closed",
                accessibilityLabel: "Translate"
            ) { [weak self] in
                self?.translateSelection()
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
            self?.copySelection()
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
        colorStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        for (color, name) in Self.annotationColors {
            let dot = ColorDotView(color: color, size: 14) { [weak self] in
                self?.applyHighlight(color: color)
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

// MARK: - Highlight Split Button

private class HighlightSplitButton: NSView {
    private var currentColor: NSColor
    private let onHighlightClick: () -> Void
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

    init(color: NSColor, onHighlightClick: @escaping () -> Void, onChevronClick: @escaping () -> Void) {
        self.currentColor = color
        self.onHighlightClick = onHighlightClick
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

        toolTip = "Highlight"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupIcon() {
        if let img = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Highlight") {
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
            onHighlightClick()
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

// MARK: - Annotation Color Change Helper

class AnnotationColorChange: NSObject {
    let annotation: PDFAnnotation
    let color: NSColor

    init(annotation: PDFAnnotation, color: NSColor) {
        self.annotation = annotation
        self.color = color
    }
}
