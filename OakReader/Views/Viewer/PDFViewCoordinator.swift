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

    /// Install or remove global event monitors when the tab becomes active/inactive.
    /// Called from `updateNSView` in response to SwiftUI state changes.
    func setActive(_ active: Bool) {
        guard let pdfView else { return }
        if active {
            // Only install if not already present
            if mouseMonitor == nil { setupMouseMonitor(for: pdfView) }
            if rightClickMonitor == nil { setupRightClickMonitor(for: pdfView) }
            if keyMonitor == nil { setupKeyMonitor() }
            if scrollMonitor == nil { setupScrollMonitor(for: pdfView) }
        } else {
            removeMouseMonitor()
            removeRightClickMonitor()
            removeKeyMonitor()
            removeScrollMonitor()
            dismissSelectionPopup()
        }
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

    // MARK: - Right-Click Context Menu

    private func setupRightClickMonitor(for pdfView: PDFView) {
        removeRightClickMonitor()

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  let pdfView = self.pdfView else { return event }

            let locationInPDFView = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(locationInPDFView) else { return event }

            // Find annotation at click point
            let page = pdfView.page(for: locationInPDFView, nearest: false)
            var annotation: PDFAnnotation?
            if let page {
                let pdfPoint = pdfView.convert(locationInPDFView, to: page)
                // Try PDFKit's built-in hit testing first
                if let hit = page.annotation(at: pdfPoint), hit.type != "Widget" {
                    annotation = hit
                } else {
                    // Fall back: check bounds and quad points for markup annotations
                    annotation = page.annotations.first { ann in
                        guard ann.type != "Widget" else { return false }
                        if ann.bounds.contains(pdfPoint) { return true }
                        // For markup annotations, check quad point rectangles
                        if let quadPoints = ann.value(forAnnotationKey: .quadPoints) as? [NSValue] {
                            for i in stride(from: 0, to: quadPoints.count - 3, by: 4) {
                                let pts = (0...3).map { quadPoints[i + $0].pointValue }
                                let quadRect = CGRect(
                                    x: min(pts[0].x, pts[2].x),
                                    y: min(pts[0].y, pts[1].y),
                                    width: max(pts[1].x, pts[3].x) - min(pts[0].x, pts[2].x),
                                    height: max(pts[2].y, pts[3].y) - min(pts[0].y, pts[1].y)
                                )
                                if quadRect.contains(pdfPoint) { return true }
                            }
                        }
                        return false
                    }
                }
            }

            let menu: NSMenu
            if let annotation {
                self.viewModel.state.selectedAnnotation = annotation
                menu = self.buildAnnotationContextMenu(for: annotation)
            } else {
                menu = self.buildGeneralContextMenu()
            }

            NSMenu.popUpContextMenu(menu, with: event, for: pdfView)
            return nil // Consume the event
        }
    }

    // MARK: - General Context Menu (empty area)

    private func buildGeneralContextMenu() -> NSMenu {
        let menu = NSMenu()

        // Zoom section
        menu.addItem(makeItem("Zoom In", action: #selector(menuZoomIn), key: "", icon: "plus.magnifyingglass"))
        menu.addItem(makeItem("Zoom Out", action: #selector(menuZoomOut), key: "", icon: "minus.magnifyingglass"))
        menu.addItem(makeItem("Zoom to Fit", action: #selector(menuZoomToFit), key: "", icon: "arrow.up.left.and.arrow.down.right.magnifyingglass"))
        menu.addItem(makeItem("Actual Size", action: #selector(menuActualSize), key: "", icon: "1.magnifyingglass"))

        menu.addItem(.separator())

        // Page navigation
        menu.addItem(makeItem("Go to Page\u{2026}", action: #selector(menuGoToPage), key: "", icon: "doc.text.magnifyingglass"))
        let prevItem = makeItem("Previous Page", action: #selector(menuPreviousPage), key: "", icon: "chevron.left")
        if viewModel.state.currentPageIndex <= 0 { prevItem.isEnabled = false }
        menu.addItem(prevItem)
        let nextItem = makeItem("Next Page", action: #selector(menuNextPage), key: "", icon: "chevron.right")
        if viewModel.state.currentPageIndex >= viewModel.pageCount - 1 { nextItem.isEnabled = false }
        menu.addItem(nextItem)

        menu.addItem(.separator())

        // Annotation tool toggles + color
        appendToolItems(to: menu)

        return menu
    }

    // MARK: - Annotation Context Menu (right-click on annotation)

    private func buildAnnotationContextMenu(for annotation: PDFAnnotation) -> NSMenu {
        let menu = NSMenu()

        // Color submenu (for this annotation)
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
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
            item.image = colorSwatchImage(color)
            if colorsAreClose(annotation.color, color) { item.state = .on }
            colorMenu.addItem(item)
        }

        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        // Delete
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteAnnotationFromMenu(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(deleteItem)

        menu.addItem(.separator())

        // Annotation tool toggles + color
        appendToolItems(to: menu)

        return menu
    }

    // MARK: - Shared Tool Items

    /// Appends Highlight / Underline toggles, Annotation Color submenu, and Area Selection toggle.
    private func appendToolItems(to menu: NSMenu) {
        let isAnnotateMode = viewModel.state.editorMode == .annotate
        let currentTool = viewModel.annotation.currentTool

        let highlightItem = makeItem("Highlight", action: #selector(menuToggleHighlight), key: "", icon: "highlighter")
        if isAnnotateMode && currentTool == .highlight { highlightItem.state = .on }
        menu.addItem(highlightItem)

        let underlineItem = makeItem("Underline", action: #selector(menuToggleUnderline), key: "", icon: "underline")
        if isAnnotateMode && currentTool == .underline { underlineItem.state = .on }
        menu.addItem(underlineItem)

        // Annotation Color submenu (tool stroke color)
        let toolColorItem = NSMenuItem(title: "Annotation Color", action: nil, keyEquivalent: "")
        toolColorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        let toolColorMenu = NSMenu()
        for entry in OakStyle.AnnotationColors.allColors {
            let item = NSMenuItem(title: entry.name, action: #selector(changeToolColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.nsColor
            item.image = colorSwatchImage(entry.nsColor)
            if colorsAreClose(viewModel.annotation.strokeColor, entry.nsColor) { item.state = .on }
            toolColorMenu.addItem(item)
        }
        toolColorItem.submenu = toolColorMenu
        menu.addItem(toolColorItem)

        menu.addItem(.separator())

        let areaItem = makeItem("Area Selection", action: #selector(menuToggleAreaSelection), key: "", icon: "rectangle.dashed")
        if viewModel.state.editorMode == .snapshot { areaItem.state = .on }
        menu.addItem(areaItem)
    }

    // MARK: - Menu Helpers

    private func makeItem(_ title: String, action: Selector, key: String, icon: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let icon {
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }
        return item
    }

    private func colorSwatchImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
            return true
        }
    }

    // MARK: - Menu Actions: Zoom

    @objc private func menuZoomIn() {
        viewModel.viewer.zoomIn()
    }

    @objc private func menuZoomOut() {
        viewModel.viewer.zoomOut()
    }

    @objc private func menuZoomToFit() {
        viewModel.viewer.zoomToFit()
    }

    @objc private func menuActualSize() {
        viewModel.viewer.zoomToActualSize()
    }

    // MARK: - Menu Actions: Page Navigation

    @objc private func menuGoToPage() {
        guard let window = pdfView?.window else { return }

        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = "Enter a page number (1–\(viewModel.pageCount)):"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.stringValue = "\(viewModel.state.currentPageIndex + 1)"
        field.alignment = .center
        alert.accessoryView = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if let page = Int(field.stringValue) {
                self.viewModel.viewer.goToPage(page - 1)
            }
        }
        // Focus the text field after sheet appears
        DispatchQueue.main.async { field.selectText(nil) }
    }

    @objc private func menuPreviousPage() {
        viewModel.viewer.goToPage(viewModel.state.currentPageIndex - 1)
    }

    @objc private func menuNextPage() {
        viewModel.viewer.goToPage(viewModel.state.currentPageIndex + 1)
    }

    // MARK: - Menu Actions: Annotation Tools

    @objc private func menuToggleHighlight() {
        toggleAnnotationTool(.highlight)
    }

    @objc private func menuToggleUnderline() {
        toggleAnnotationTool(.underline)
    }

    private func toggleAnnotationTool(_ tool: AnnotationTool) {
        let isActive = viewModel.state.editorMode == .annotate && viewModel.annotation.currentTool == tool
        if isActive {
            viewModel.annotation.currentTool = .none
            viewModel.setEditorMode(.viewer)
        } else {
            viewModel.annotation.currentTool = tool
            viewModel.setEditorMode(.annotate)
        }
    }

    @objc private func changeToolColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        viewModel.annotation.strokeColor = color
    }

    @objc private func menuToggleAreaSelection() {
        if viewModel.state.editorMode == .snapshot {
            viewModel.setEditorMode(.viewer)
        } else {
            viewModel.setEditorMode(.snapshot)
        }
    }

    // MARK: - Annotation Actions

    @objc private func changeAnnotationColor(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? AnnotationColorChange else { return }
        viewModel.annotation.updateAnnotationColor(change.annotation, color: change.color)
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
