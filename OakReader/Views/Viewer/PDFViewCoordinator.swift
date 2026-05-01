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

            // Dismiss popup on any mouse down (but not clicks on the popup itself or its sub-panels)
            if event.type == .leftMouseDown {
                if let popup = self.selectionPopup, let eventWindow = event.window, popup.ownsWindow(eventWindow) {
                    // Click is on the popup panel or its color sub-panel — let it handle it
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
        // Use maxY (top of selection) so popup appears above the selected text
        let viewPoint = pdfView.convert(
            NSPoint(x: selBounds.midX, y: selBounds.maxY),
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
            anchorPoint: NSPoint(x: selBounds.midX, y: selBounds.maxY)
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
    }

    private func handleMouseDragged(event: NSEvent, pdfView: PDFView, tool: AnnotationTool) {
        let point = pdfView.convert(event.locationInWindow, from: nil)
    }

    private func handleMouseUp(event: NSEvent, pdfView: PDFView, tool: AnnotationTool) {
        let endPoint = pdfView.convert(event.locationInWindow, from: nil)

        guard let startPoint = dragStart,
              let page = pdfView.currentPage,
              let doc = pdfView.document else {
            dragStart = nil
            return
        }

        let pageIndex = doc.index(for: page)

        // Convert view points to PDF page coordinates
        let pdfStart = pdfView.convert(startPoint, to: page)
        let _ = pdfView.convert(endPoint, to: page)

        switch tool {
        default:
            break
        }

        dragStart = nil
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
