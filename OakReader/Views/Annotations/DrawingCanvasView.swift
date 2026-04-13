import SwiftUI
import AppKit

struct DrawingCanvasView: NSViewRepresentable {
    var lineColor: NSColor
    var lineWidth: CGFloat
    var onStrokeCompleted: (([CGPoint]) -> Void)?
    var onDrawingCompleted: (([[CGPoint]]) -> Void)?

    func makeNSView(context: Context) -> DrawingCanvas {
        let canvas = DrawingCanvas()
        canvas.strokeColor = lineColor
        canvas.strokeWidth = lineWidth
        canvas.onStrokeCompleted = onStrokeCompleted
        canvas.onDrawingCompleted = onDrawingCompleted
        return canvas
    }

    func updateNSView(_ nsView: DrawingCanvas, context: Context) {
        nsView.strokeColor = lineColor
        nsView.strokeWidth = lineWidth
    }
}

class DrawingCanvas: NSView {
    var strokeColor: NSColor = .black
    var strokeWidth: CGFloat = 2.0
    var onStrokeCompleted: (([CGPoint]) -> Void)?
    var onDrawingCompleted: (([[CGPoint]]) -> Void)?

    private var allStrokes: [[CGPoint]] = []
    private var currentStroke: [CGPoint] = []
    private var currentPath: NSBezierPath?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.white.setFill()
        dirtyRect.fill()

        // Draw border
        NSColor.separatorColor.setStroke()
        let borderPath = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 1
        borderPath.stroke()

        // Draw completed strokes
        strokeColor.setStroke()
        for stroke in allStrokes {
            drawStroke(stroke)
        }

        // Draw current stroke
        if !currentStroke.isEmpty {
            drawStroke(currentStroke)
        }
    }

    private func drawStroke(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentStroke = [point]
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentStroke.append(point)
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        if currentStroke.count > 1 {
            allStrokes.append(currentStroke)
            onStrokeCompleted?(currentStroke)
        }
        currentStroke = []
        setNeedsDisplay(bounds)
    }

    func clear() {
        allStrokes.removeAll()
        currentStroke.removeAll()
        setNeedsDisplay(bounds)
    }

    func completeDrawing() {
        onDrawingCompleted?(allStrokes)
    }

    var hasStrokes: Bool {
        !allStrokes.isEmpty
    }
}
