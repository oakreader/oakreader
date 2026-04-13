import SwiftUI
import PDFKit
import AppKit

struct SnapshotOverlayView: View {
    let viewModel: DocumentViewModel

    @State private var isDragging = false
    @State private var showSelection = false
    @State private var dragStart = CGPoint.zero
    @State private var dragEnd = CGPoint.zero

    var body: some View {
        ZStack {
            // Transparent hit-test area that only captures drags, passes scroll events through
            SnapshotHitTestView(
                isActive: viewModel.state.editorMode == .snapshot,
                onDragChanged: { start, current in
                    if !isDragging {
                        isDragging = true
                        showSelection = false
                        dragStart = start
                    }
                    dragEnd = current
                },
                onDragEnded: { start, end in
                    dragEnd = end
                    isDragging = false
                    showSelection = true
                    finishSelection()
                }
            )

            // Selection rectangle (dashed border while dragging or popup is open)
            if isDragging || showSelection {
                let rect = normalizedRect(from: dragStart, to: dragEnd)
                Rectangle()
                    .strokeBorder(
                        Color(nsColor: viewModel.annotation.strokeColor),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func finishSelection() {
        let selectionRect = normalizedRect(from: dragStart, to: dragEnd)
        guard selectionRect.width > 10, selectionRect.height > 10 else {
            showSelection = false
            return
        }

        guard let window = NSApp.keyWindow,
              let pdfView = findPDFView(in: window.contentView),
              let hitTestView = findSnapshotHitTestView(in: window.contentView) else {
            showSelection = false
            return
        }

        guard let doc = pdfView.document else {
            showSelection = false
            return
        }

        // Convert from flipped overlay coords (SwiftUI, Y-down) to NSView coords (AppKit, Y-up)
        let overlayHeight = hitTestView.bounds.height
        let nsPoint1 = NSPoint(x: selectionRect.minX, y: overlayHeight - selectionRect.minY)
        let nsPoint2 = NSPoint(x: selectionRect.maxX, y: overlayHeight - selectionRect.maxY)

        // Convert from overlay NSView coords → PDFView coords
        let pdfViewPoint1 = hitTestView.convert(nsPoint1, to: pdfView)
        let pdfViewPoint2 = hitTestView.convert(nsPoint2, to: pdfView)
        let pdfViewCenter = NSPoint(
            x: (pdfViewPoint1.x + pdfViewPoint2.x) / 2,
            y: (pdfViewPoint1.y + pdfViewPoint2.y) / 2
        )

        // Find the page at the center of the selection
        guard let page = pdfView.page(for: pdfViewCenter, nearest: true) else {
            showSelection = false
            return
        }

        // Convert from PDFView coords → PDF page coords
        let pdfPoint1 = pdfView.convert(pdfViewPoint1, to: page)
        let pdfPoint2 = pdfView.convert(pdfViewPoint2, to: page)

        let pdfRect = CGRect(
            x: min(pdfPoint1.x, pdfPoint2.x),
            y: min(pdfPoint1.y, pdfPoint2.y),
            width: abs(pdfPoint2.x - pdfPoint1.x),
            height: abs(pdfPoint2.y - pdfPoint1.y)
        )

        guard pdfRect.width > 1, pdfRect.height > 1 else {
            showSelection = false
            return
        }

        let pageIndex = doc.index(for: page)

        // Get screen position for popup (bottom of selection visually)
        // In AppKit coords (Y-up), the visual bottom is the smaller Y value
        let bottomCenterNS = NSPoint(
            x: (nsPoint1.x + nsPoint2.x) / 2,
            y: min(nsPoint1.y, nsPoint2.y)
        )
        let windowPoint = hitTestView.convert(bottomCenterNS, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        // Show the area selection popup
        AreaSelectionPopupPanel.show(
            at: screenPoint,
            pdfRect: pdfRect,
            page: page,
            pageIndex: pageIndex,
            viewModel: viewModel,
            annotationColor: viewModel.annotation.strokeColor,
            onDismiss: { [self] in
                showSelection = false
            }
        )
    }

    private func findPDFView(in view: NSView?) -> PDFView? {
        guard let view else { return nil }
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let found = findPDFView(in: subview) { return found }
        }
        return nil
    }

    private func findSnapshotHitTestView(in view: NSView?) -> SnapshotHitTestNSView? {
        guard let view else { return nil }
        if let hitView = view as? SnapshotHitTestNSView { return hitView }
        for subview in view.subviews {
            if let found = findSnapshotHitTestView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - Hit-test view that captures drags but forwards scroll events

private struct SnapshotHitTestView: NSViewRepresentable {
    let isActive: Bool
    let onDragChanged: (_ start: CGPoint, _ current: CGPoint) -> Void
    let onDragEnded: (_ start: CGPoint, _ end: CGPoint) -> Void

    func makeNSView(context: Context) -> SnapshotHitTestNSView {
        let view = SnapshotHitTestNSView()
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: SnapshotHitTestNSView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.updateActive(isActive)
    }
}

/// Transparent overlay that uses an NSEvent monitor to capture mouse drags
/// for area selection, while letting ALL other events (scroll, scrollbar clicks,
/// magnify, etc.) pass through to the PDFView naturally.
class SnapshotHitTestNSView: NSView {
    var isActive = false
    var onDragChanged: ((_ start: CGPoint, _ current: CGPoint) -> Void)?
    var onDragEnded: ((_ start: CGPoint, _ end: CGPoint) -> Void)?

    private var mouseMonitor: Any?
    private var dragStartPoint: CGPoint?  // in flipped (SwiftUI) coords
    private var isDragging = false

    // Always transparent to hit-testing — never blocks scrollbars or scroll events
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateActive(_ active: Bool) {
        let wasActive = isActive
        isActive = active
        if active && !wasActive {
            installMonitor()
        } else if !active && wasActive {
            removeMonitor()
        }
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
    }

    private func installMonitor() {
        removeMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.isActive else { return event }
            return self.handleMouseEvent(event)
        }
    }

    private func removeMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        dragStartPoint = nil
        isDragging = false
    }

    private func isPointOnScrollbar(_ windowPoint: NSPoint) -> Bool {
        guard let pdfView = findPDFView(),
              let scrollView = pdfView.enclosingScrollView ?? pdfView.subviews.compactMap({ $0 as? NSScrollView }).first else {
            return false
        }
        if let vScroller = scrollView.verticalScroller, !vScroller.isHidden {
            let pt = vScroller.convert(windowPoint, from: nil)
            if vScroller.bounds.contains(pt) { return true }
        }
        if let hScroller = scrollView.horizontalScroller, !hScroller.isHidden {
            let pt = hScroller.convert(windowPoint, from: nil)
            if hScroller.bounds.contains(pt) { return true }
        }
        return false
    }

    private weak var cachedPDFView: PDFView?

    private func findPDFView() -> PDFView? {
        if let cached = cachedPDFView { return cached }
        guard let root = window?.contentView else { return nil }
        let found = Self.searchForPDFView(in: root)
        cachedPDFView = found
        return found
    }

    private static func searchForPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let found = searchForPDFView(in: subview) { return found }
        }
        return nil
    }

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        // Only intercept events targeting our own window — pass through events
        // for floating panels (popup menus, area selection popup, etc.)
        guard event.window === self.window else { return event }

        let localPoint = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: localPoint.x, y: bounds.height - localPoint.y)

        switch event.type {
        case .leftMouseDown:
            // Pass through clicks on scrollbars
            if isPointOnScrollbar(event.locationInWindow) { return event }
            guard bounds.contains(localPoint) else { return event }
            dragStartPoint = flipped
            isDragging = false
            // Consume mouseDown so PDFView doesn't capture the mouse tracking loop
            return nil

        case .leftMouseDragged:
            guard dragStartPoint != nil else { return event }
            onDragChanged?(dragStartPoint!, flipped)
            isDragging = true
            return nil

        case .leftMouseUp:
            guard let start = dragStartPoint else { return event }
            dragStartPoint = nil
            if isDragging {
                isDragging = false
                let distance = hypot(flipped.x - start.x, flipped.y - start.y)
                if distance >= 5 {
                    onDragEnded?(start, flipped)
                }
            }
            return nil

        default:
            return event
        }
    }

    override func resetCursorRects() {
        if isActive {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        if isActive {
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .cursorUpdate, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isActive {
            NSCursor.crosshair.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cachedPDFView = nil
        if isActive && window != nil {
            installMonitor()
        } else if window == nil {
            removeMonitor()
        }
    }

    deinit {
        removeMonitor()
    }
}

// MARK: - Crosshair cursor modifier

private struct CursorModifier: ViewModifier {
    let cursor: NSCursor
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }
}

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

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep2)

        // Row 3: Copy Image (full width)
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
        let renderService = PDFRenderingService()
        guard let cgImage = renderService.renderPageRegion(page, region: pdfRect, dpi: 300) else {
            dismiss()
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            dismiss()
            return
        }

        viewModel.chat.addImageAttachment(pngData, pageIndex: pageIndex)
        viewModel.state.rightPanelMode = .aiChat
        dismiss()
    }

    private func copyImage() {
        let renderService = PDFRenderingService()
        guard let cgImage = renderService.renderPageRegion(page, region: pdfRect, dpi: 300) else {
            dismiss()
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])

        dismiss()

        // Show brief "Copied" feedback via notification
        showCopiedToast()
    }

    private func addAreaAnnotation(color: NSColor) {
        // Create a square (rectangle) annotation with colored border, no fill — like Zotero
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

// MARK: - Color Dot (Zotero-style round swatch for area popup)

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

// MARK: - Popup Action Button for Area Popup (icon + label, Zotero-style)

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
