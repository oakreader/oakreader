import AppKit
import PDFKit

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
