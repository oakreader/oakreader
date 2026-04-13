import Foundation
import PDFKit
import AppKit
import Combine

class PDFViewCoordinator: NSObject, PDFViewDelegate {
    var viewModel: DocumentViewModel
    weak var pdfView: PDFView?
    var isAutoScaling = false
    private var pageChangeObserver: Any?
    private var scaleChangeObserver: Any?
    private var annotationHitObserver: Any?

    // Annotation interaction
    private var mouseMonitor: Any?
    private var rightClickMonitor: Any?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var dragStart: NSPoint?
    private var currentDrawingPoints: [CGPoint] = []

    // Text selection popup
    private var selectionPopup: TextSelectionPopupPanel?
    private var selectionChangeObserver: Any?

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func setupObservers(for pdfView: PDFView) {
        removeObservers()

        let center = NotificationCenter.default

        pageChangeObserver = center.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let index = doc.index(for: currentPage)
            if self.viewModel.state.currentPageIndex != index {
                self.viewModel.state.currentPageIndex = index
            }
        }

        scaleChangeObserver = center.addObserver(
            forName: .PDFViewScaleChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let pdfView = notification.object as? PDFView else { return }
            let newZoom = pdfView.scaleFactor
            if abs(self.viewModel.state.zoomLevel - newZoom) > 0.001 {
                self.viewModel.state.zoomLevel = newZoom
            }
        }

        annotationHitObserver = center.addObserver(
            forName: .PDFViewAnnotationHit,
            object: pdfView,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation else { return }
            self.viewModel.state.selectedAnnotation = annotation
        }

        selectionChangeObserver = center.addObserver(
            forName: .PDFViewSelectionChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let pdfView = notification.object as? PDFView else { return }
            self.updateSelectionState(pdfView: pdfView)
        }

        setupMouseMonitor(for: pdfView)
        setupRightClickMonitor(for: pdfView)
        setupKeyMonitor()
        setupScrollMonitor(for: pdfView)
    }

    // MARK: - Mouse Monitor for Annotation Tools

    private func setupMouseMonitor(for pdfView: PDFView) {
        removeMouseMonitor()

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self,
                  let pdfView = self.pdfView else { return event }

            // Dismiss popup on any mouse down (but not clicks on the popup itself)
            if event.type == .leftMouseDown {
                if let popup = self.selectionPopup, event.window === popup {
                    // Click is on the popup panel — let it handle it
                } else {
                    self.dismissSelectionPopup()
                }
            }

            let mode = self.viewModel.state.editorMode

            // In viewer mode: detect text selection on mouse up → show popup
            if mode == .viewer {
                if event.type == .leftMouseUp {
                    let locationInPDFView = pdfView.convert(event.locationInWindow, from: nil)
                    if pdfView.bounds.contains(locationInPDFView) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.showSelectionPopupIfNeeded(pdfView: pdfView)
                        }
                    }
                }
                return event
            }

            guard mode == .annotate else { return event }

            let tool = self.viewModel.annotation.currentTool

            // Select tool — pass all events to PDFView (for annotation selection, text selection)
            if tool == .none {
                if event.type == .leftMouseUp {
                    let locationInPDFView = pdfView.convert(event.locationInWindow, from: nil)
                    if pdfView.bounds.contains(locationInPDFView) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.showSelectionPopupIfNeeded(pdfView: pdfView)
                        }
                    }
                }
                return event
            }

            // Check if event is within the PDFView
            let locationInPDFView = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(locationInPDFView) else { return event }

            // Text markup tools: let PDFView handle text selection normally,
            // but apply annotation on mouse up
            if tool == .highlight || tool == .underline {
                if event.type == .leftMouseUp {
                    // Delay slightly to let PDFView finish updating its selection
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.applyTextMarkup(pdfView: pdfView, tool: tool)
                    }
                }
                return event // Pass through so PDFView handles text selection
            }

            // Drawing/shape/note tools: consume events
            switch event.type {
            case .leftMouseDown:
                self.handleMouseDown(event: event, pdfView: pdfView, tool: tool)
                return nil
            case .leftMouseDragged:
                self.handleMouseDragged(event: event, pdfView: pdfView, tool: tool)
                return nil
            case .leftMouseUp:
                self.handleMouseUp(event: event, pdfView: pdfView, tool: tool)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Text Selection Popup

    private func showSelectionPopupIfNeeded(pdfView: PDFView) {
        guard let selection = pdfView.currentSelection,
              let selString = selection.string,
              !selString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Get the selection bounds in screen coordinates
        guard let page = selection.pages.first else { return }
        let selBounds = selection.bounds(for: page)

        // Convert PDF page coords → PDFView coords → screen coords
        let viewPoint = pdfView.convert(
            NSPoint(x: selBounds.midX, y: selBounds.minY),
            from: page
        )
        guard let window = pdfView.window else { return }
        let windowPoint = pdfView.convert(viewPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        // Dismiss old popup without auto-highlight (we're replacing it)
        selectionPopup?.autoHighlightOnDismiss = false
        dismissSelectionPopup()

        let popup = TextSelectionPopupPanel(
            at: screenPoint,
            viewModel: viewModel,
            selection: selection,
            pdfView: pdfView,
            anchorPage: page,
            anchorPoint: NSPoint(x: selBounds.midX, y: selBounds.minY)
        ) { [weak self] in
            self?.selectionPopup = nil
        }
        selectionPopup = popup
    }

    private func dismissSelectionPopup() {
        selectionPopup?.dismiss()
        selectionPopup = nil
    }

    // MARK: - Selection State for AI Chat

    private func updateSelectionState(pdfView: PDFView) {
        guard let selection = pdfView.currentSelection,
              let selString = selection.string,
              !selString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            viewModel.state.selectedText = nil
            return
        }

        viewModel.state.selectedText = selString
    }

    // MARK: - Right-Click Context Menu on Annotations

    private func setupRightClickMonitor(for pdfView: PDFView) {
        removeRightClickMonitor()

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  let pdfView = self.pdfView else { return event }

            let locationInPDFView = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(locationInPDFView) else { return event }

            // Find annotation at click point
            guard let page = pdfView.page(for: locationInPDFView, nearest: false) else { return event }
            let pdfPoint = pdfView.convert(locationInPDFView, to: page)

            let annotation = page.annotations.first { ann in
                ann.bounds.contains(pdfPoint) && ann.type != "Widget"
            }

            guard let annotation else { return event }

            // Select it
            self.viewModel.state.selectedAnnotation = annotation

            // Build and show context menu
            let menu = self.buildAnnotationContextMenu(for: annotation)
            NSMenu.popUpContextMenu(menu, with: event, for: pdfView)
            return nil // Consume the event
        }
    }

    private func buildAnnotationContextMenu(for annotation: PDFAnnotation) -> NSMenu {
        let menu = NSMenu()

        // Color submenu
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()

        let colors: [(String, NSColor)] = [
            ("Yellow", .systemYellow),
            ("Red", .systemRed),
            ("Green", .systemGreen),
            ("Blue", .systemBlue),
            ("Purple", .systemPurple),
            ("Orange", .systemOrange),
            ("Pink", .systemPink),
            ("Gray", .systemGray),
        ]

        for (name, color) in colors {
            let item = NSMenuItem(title: name, action: #selector(changeAnnotationColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = AnnotationColorChange(annotation: annotation, color: color)

            // Color swatch
            let size = NSSize(width: 14, height: 14)
            let image = NSImage(size: size, flipped: false) { rect in
                color.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
                return true
            }
            item.image = image

            // Checkmark for current color
            if colorsAreClose(annotation.color, color) {
                item.state = .on
            }

            colorMenu.addItem(item)
        }

        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.addItem(.separator())

        // Delete
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteAnnotationFromMenu(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        menu.addItem(deleteItem)

        return menu
    }

    @objc private func changeAnnotationColor(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? AnnotationColorChange else { return }
        let alpha = change.annotation.color.alphaComponent
        change.annotation.color = change.color.withAlphaComponent(alpha)
        viewModel.markDocumentEdited()
        viewModel.annotation.refreshAnnotationModels()
    }

    @objc private func deleteAnnotationFromMenu(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        viewModel.annotation.deleteAnnotation(annotation)
    }

    private func colorsAreClose(_ c1: NSColor, _ c2: NSColor) -> Bool {
        guard let c1RGB = c1.usingColorSpace(.sRGB),
              let c2RGB = c2.usingColorSpace(.sRGB) else { return false }
        let threshold: CGFloat = 0.15
        return abs(c1RGB.redComponent - c2RGB.redComponent) < threshold
            && abs(c1RGB.greenComponent - c2RGB.greenComponent) < threshold
            && abs(c1RGB.blueComponent - c2RGB.blueComponent) < threshold
    }

    // MARK: - Key Monitor (Delete annotations)

    private func setupKeyMonitor() {
        removeKeyMonitor()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.viewModel.state.editorMode == .annotate,
                  let annotation = self.viewModel.state.selectedAnnotation else { return event }

            // Delete or Backspace
            if event.keyCode == 51 || event.keyCode == 117 {
                self.viewModel.annotation.deleteAnnotation(annotation)
                return nil // Consume event
            }
            return event
        }
    }

    // MARK: - Scroll Zoom (Cmd + Scroll Wheel)

    private func setupScrollMonitor(for pdfView: PDFView) {
        removeScrollMonitor()

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let pdfView = self.pdfView,
                  event.modifierFlags.contains(.command) else { return event }

            // Only handle events within the PDF view
            let locationInView = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(locationInView) else { return event }

            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return nil }

            // Use a smooth zoom factor proportional to scroll delta
            let zoomFactor: CGFloat = 1.0 + (delta * 0.01)
            let newZoom = pdfView.scaleFactor * zoomFactor
            self.viewModel.viewer.setZoom(newZoom)

            return nil // Consume the event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    // MARK: - Text Markup

    private func applyTextMarkup(pdfView: PDFView, tool: AnnotationTool) {
        guard let selection = pdfView.currentSelection,
              let selString = selection.string,
              !selString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        switch tool {
        case .highlight:
            viewModel.annotation.addHighlight(for: selection)
        case .underline:
            viewModel.annotation.addUnderline(for: selection)
        default:
            break
        }

        pdfView.clearSelection()
    }

    // MARK: - Drawing Tool Mouse Handling

    private func handleMouseDown(event: NSEvent, pdfView: PDFView, tool: AnnotationTool) {
        let point = pdfView.convert(event.locationInWindow, from: nil)
        dragStart = point
        currentDrawingPoints = [point]
    }

    private func handleMouseDragged(event: NSEvent, pdfView: PDFView, tool: AnnotationTool) {
        let point = pdfView.convert(event.locationInWindow, from: nil)
        currentDrawingPoints.append(point)
    }

    private func handleMouseUp(event: NSEvent, pdfView: PDFView, tool: AnnotationTool) {
        let endPoint = pdfView.convert(event.locationInWindow, from: nil)

        guard let startPoint = dragStart,
              let page = pdfView.currentPage,
              let doc = pdfView.document else {
            dragStart = nil
            currentDrawingPoints = []
            return
        }

        let pageIndex = doc.index(for: page)

        // Convert view points to PDF page coordinates
        let pdfStart = pdfView.convert(startPoint, to: page)
        let _ = pdfView.convert(endPoint, to: page)

        switch tool {
        case .stickyNote:
            viewModel.annotation.addStickyNote(at: pdfStart, on: pageIndex)

        case .freeText:
            viewModel.annotation.addFreeText(at: pdfStart, on: pageIndex)

        case .freehand:
            let pdfPoints = currentDrawingPoints.map { pdfView.convert($0, to: page) }
            if pdfPoints.count > 1 {
                viewModel.annotation.addFreehandStroke([pdfPoints], on: pageIndex)
            }

        case .eraser:
            // Eraser: remove ink annotations whose bounds intersect the drag path
            let eraserRadius = viewModel.annotation.eraserSize / 2
            let pdfPoints = currentDrawingPoints.map { pdfView.convert($0, to: page) }
            var didErase = false
            for point in pdfPoints {
                let eraserRect = CGRect(
                    x: point.x - eraserRadius,
                    y: point.y - eraserRadius,
                    width: eraserRadius * 2,
                    height: eraserRadius * 2
                )
                let toRemove = page.annotations.filter { annotation in
                    annotation.type == "Ink" && annotation.bounds.intersects(eraserRect)
                }
                for annotation in toRemove {
                    page.removeAnnotation(annotation)
                    didErase = true
                }
            }
            if didErase {
                viewModel.markDocumentEdited()
                viewModel.annotation.refreshAnnotationModels()
            }

        default:
            break
        }

        dragStart = nil
        currentDrawingPoints = []
    }

    // MARK: - Cleanup

    private func removeRightClickMonitor() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    func removeObservers() {
        let center = NotificationCenter.default
        if let obs = pageChangeObserver { center.removeObserver(obs) }
        if let obs = scaleChangeObserver { center.removeObserver(obs) }
        if let obs = annotationHitObserver { center.removeObserver(obs) }
        if let obs = selectionChangeObserver { center.removeObserver(obs) }
        pageChangeObserver = nil
        scaleChangeObserver = nil
        annotationHitObserver = nil
        selectionChangeObserver = nil
        removeMouseMonitor()
        removeRightClickMonitor()
        removeKeyMonitor()
        removeScrollMonitor()
        dismissSelectionPopup()
    }

    deinit {
        removeObservers()
    }

    // MARK: - PDFViewDelegate

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        let allowedSchemes: Set<String> = ["http", "https", "mailto"]
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}


// MARK: - Text Selection Popup Panel (Zotero-style)

private class TextSelectionPopupPanel: NSPanel {
    private let viewModel: DocumentViewModel
    private let selection: PDFSelection
    private weak var pdfView: PDFView?
    private let onDismiss: () -> Void

    // When true, dismissing the popup (e.g. clicking outside) auto-applies highlight
    var autoHighlightOnDismiss = true

    // Anchor in PDF coordinate space so we can reposition on scroll
    private let anchorPage: PDFPage
    private let anchorPoint: NSPoint // PDF page coords: midX of selection, minY (bottom)
    private var scrollObserver: NSObjectProtocol?

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

        // Position: centered below selection
        let x = screenPoint.x - contentSize.width / 2
        let y = screenPoint.y - contentSize.height - 6
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
        // PDFView's document view is inside a scroll view; observe its clip view bounds changes
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
        let y = screenPoint.y - panelSize.height - 6
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func buildContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        // Row 1: Color dots — click to instantly highlight in that color
        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 10
        colorRow.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        for (color, name) in Self.annotationColors {
            let dot = ColorDotView(color: color, size: 20) { [weak self] in
                self?.applyHighlightKeepOpen(color: color)
            }
            dot.toolTip = name
            colorRow.addArrangedSubview(dot)
        }
        stack.addArrangedSubview(colorRow)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)

        // Row 2: Highlight (full width)
        let highlightBtn = PopupActionButton(
            systemImage: "highlighter",
            title: "Highlight"
        ) { [weak self] in
            self?.applyHighlight(color: self?.viewModel.annotation.strokeColor ?? NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0))
        }
        stack.addArrangedSubview(highlightBtn)
        highlightBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        highlightBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Row 3: Underline (full width)
        let underlineBtn = PopupActionButton(
            systemImage: "underline",
            title: "Underline"
        ) { [weak self] in
            self?.applyUnderline()
        }
        stack.addArrangedSubview(underlineBtn)
        underlineBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        underlineBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep2)

        // Row 4: Add to Chat (full width)
        let addToChatBtn = PopupActionButton(
            systemImage: "bubble.left",
            title: "Add to Chat"
        ) { [weak self] in
            self?.addToChat()
        }
        stack.addArrangedSubview(addToChatBtn)
        addToChatBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        addToChatBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Separator
        let sep3 = NSBox()
        sep3.boxType = .separator
        sep3.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep3)

        // Row 4: Copy (full width)
        let copyBtn = PopupActionButton(
            systemImage: "doc.on.doc",
            title: "Copy"
        ) { [weak self] in
            self?.copySelection()
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
        guard let text = selection.string, !text.isEmpty else { return }
        let pageIndex = viewModel.state.currentPageIndex
        viewModel.chat.addTextAttachment(text, pageIndex: pageIndex)
        viewModel.state.rightPanelMode = .aiChat
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func applyHighlightKeepOpen(color: NSColor) {
        viewModel.annotation.strokeColor = color
        viewModel.annotation.addHighlight(for: selection)
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

    /// Dismiss after an explicit action (no auto-highlight needed)
    private func dismissWithAction() {
        autoHighlightOnDismiss = false
        dismiss()
    }

    /// Dismiss the popup. If autoHighlightOnDismiss is true (user clicked outside),
    /// automatically apply highlight in the current color — Zotero-style behavior.
    func dismiss() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }

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

// MARK: - Color Dot (Zotero-style round swatch)

private class ColorDotView: NSView {
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

// MARK: - Popup Action Button (icon + label, Zotero-style)

private class PopupActionButton: NSButton {
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

    @objc private func clicked() {
        onClick()
    }
}

// Helper to pass annotation + color through NSMenuItem.representedObject
private class AnnotationColorChange: NSObject {
    let annotation: PDFAnnotation
    let color: NSColor

    init(annotation: PDFAnnotation, color: NSColor) {
        self.annotation = annotation
        self.color = color
    }
}
