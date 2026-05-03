import SwiftUI

struct MediaSnapshotOverlayView: View {
    let viewModel: DocumentViewModel

    @State private var isDragging = false
    @State private var showSelection = false
    @State private var dragStart = CGPoint.zero
    @State private var dragEnd = CGPoint.zero

    var body: some View {
        ZStack {
            // Transparent hit-test area that only captures drags, passes scroll events through
            MediaSnapshotHitTestView(
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
                        Color.accentColor,
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
              let contentView = window.contentView,
              let hitTestView = findMediaSnapshotHitTestView(in: contentView) else {
            showSelection = false
            return
        }

        // Convert from flipped overlay coords (SwiftUI, Y-down) to NSView coords (AppKit, Y-up)
        let overlayHeight = hitTestView.bounds.height
        let nsPoint1 = NSPoint(x: selectionRect.minX, y: overlayHeight - selectionRect.minY)
        let nsPoint2 = NSPoint(x: selectionRect.maxX, y: overlayHeight - selectionRect.maxY)

        // Convert from overlay NSView coords → window content view coords
        let contentPoint1 = hitTestView.convert(nsPoint1, to: contentView)
        let contentPoint2 = hitTestView.convert(nsPoint2, to: contentView)

        // Build the capture rect in content view coordinates (Y-up AppKit)
        let captureRect = CGRect(
            x: min(contentPoint1.x, contentPoint2.x),
            y: min(contentPoint1.y, contentPoint2.y),
            width: abs(contentPoint2.x - contentPoint1.x),
            height: abs(contentPoint2.y - contentPoint1.y)
        )

        guard captureRect.width > 1, captureRect.height > 1 else {
            showSelection = false
            return
        }

        // Get screen position for popup (bottom-center of selection in screen coords)
        let bottomCenterNS = NSPoint(
            x: (nsPoint1.x + nsPoint2.x) / 2,
            y: min(nsPoint1.y, nsPoint2.y)
        )
        let windowPoint = hitTestView.convert(bottomCenterNS, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        // Hide the selection overlay before capture so it doesn't appear in the screenshot
        showSelection = false

        // Use a short delay to allow SwiftUI to remove the selection overlay before capturing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Capture the region using cacheDisplay on the window's content view
            let backingScale = window.backingScaleFactor
            let pixelRect = CGRect(
                x: captureRect.origin.x * backingScale,
                y: captureRect.origin.y * backingScale,
                width: captureRect.width * backingScale,
                height: captureRect.height * backingScale
            )

            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: captureRect) else {
                return
            }
            contentView.cacheDisplay(in: captureRect, to: bitmap)

            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return
            }

            // Re-show selection and present popup
            self.showSelection = true
            WebAreaPopupPanel.show(
                at: screenPoint,
                imageData: pngData,
                viewModel: viewModel,
                onDismiss: { self.showSelection = false }
            )
        }
    }

    private func findMediaSnapshotHitTestView(in view: NSView?) -> MediaSnapshotHitTestNSView? {
        guard let view else { return nil }
        if let hitView = view as? MediaSnapshotHitTestNSView { return hitView }
        for subview in view.subviews {
            if let found = findMediaSnapshotHitTestView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - SwiftUI wrapper

private struct MediaSnapshotHitTestView: NSViewRepresentable {
    let isActive: Bool
    let onDragChanged: (_ start: CGPoint, _ current: CGPoint) -> Void
    let onDragEnded: (_ start: CGPoint, _ end: CGPoint) -> Void

    func makeNSView(context: Context) -> MediaSnapshotHitTestNSView {
        let view = MediaSnapshotHitTestNSView()
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: MediaSnapshotHitTestNSView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.updateActive(isActive)
    }
}

// MARK: - Hit-test NSView for media area selection

/// Transparent overlay that uses an NSEvent monitor to capture mouse drags
/// for area selection, while letting ALL other events (scroll, etc.) pass through
/// to the underlying media viewer naturally.
class MediaSnapshotHitTestNSView: NSView {
    var isActive = false
    var onDragChanged: ((_ start: CGPoint, _ current: CGPoint) -> Void)?
    var onDragEnded: ((_ start: CGPoint, _ end: CGPoint) -> Void)?

    private var mouseMonitor: Any?
    private var dragStartPoint: CGPoint?  // in flipped (SwiftUI) coords
    private var isDragging = false

    // Always transparent to hit-testing — never blocks scroll events
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

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        // Only intercept events targeting our own window
        guard event.window === self.window else { return event }

        let localPoint = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: localPoint.x, y: bounds.height - localPoint.y)

        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(localPoint) else { return event }
            dragStartPoint = flipped
            isDragging = false
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
