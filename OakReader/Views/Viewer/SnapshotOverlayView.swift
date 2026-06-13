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

