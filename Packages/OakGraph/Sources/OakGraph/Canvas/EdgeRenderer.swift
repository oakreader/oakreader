import SwiftUI

/// Draws edges on a SwiftUI Canvas context.
public struct EdgeRenderer {

    /// Draw a single edge between two nodes.
    public static func draw(
        edge: EdgeModel,
        source: NodeModel,
        target: NodeModel,
        isSelected: Bool,
        in context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        let style = edge.style
        let color = Color(hex: style.colorHex)

        // Compute connection points at node boundaries
        let start = nodeEdgeIntersection(node: source, toward: target.position)
        let end = nodeEdgeIntersection(node: target, toward: source.position)

        // Build the line path
        var linePath = Path()
        var midpoint: CGPoint

        switch style.lineType {
        case .straight:
            linePath.move(to: start)
            linePath.addLine(to: end)
            midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)

        case .bezier:
            let (cp1, cp2) = bezierControlPoints(from: start, to: end)
            linePath.move(to: start)
            linePath.addCurve(to: end, control1: cp1, control2: cp2)
            midpoint = bezierMidpoint(start: start, cp1: cp1, cp2: cp2, end: end)

        case .orthogonal:
            let midX = (start.x + end.x) / 2
            linePath.move(to: start)
            linePath.addLine(to: CGPoint(x: midX, y: start.y))
            linePath.addLine(to: CGPoint(x: midX, y: end.y))
            linePath.addLine(to: end)
            midpoint = CGPoint(x: midX, y: (start.y + end.y) / 2)
        }

        // Stroke style
        let strokeStyle: StrokeStyle
        if style.isDashed {
            strokeStyle = StrokeStyle(lineWidth: style.thickness, dash: [8, 4])
        } else {
            strokeStyle = StrokeStyle(lineWidth: style.thickness)
        }

        // Selection highlight (wider stroke behind)
        if isSelected {
            context.stroke(
                linePath,
                with: .color(.accentColor.opacity(0.3)),
                style: StrokeStyle(lineWidth: style.thickness + 4)
            )
        }

        // Draw the line
        context.stroke(linePath, with: .color(color), style: strokeStyle)

        // Draw arrowheads
        drawArrowhead(style.sourceArrow, at: start, toward: end, color: color, in: &context)
        drawArrowhead(style.targetArrow, at: end, toward: start, color: color, in: &context)

        // Draw edge label
        if !edge.label.isEmpty {
            drawLabel(edge.label, at: midpoint, fontSize: style.labelFontSize, in: &context)
        }
    }

    // MARK: - Arrowheads

    private static func drawArrowhead(
        _ type: ArrowHead,
        at point: CGPoint,
        toward other: CGPoint,
        color: Color,
        in context: inout GraphicsContext
    ) {
        guard type != .none else { return }

        let angle = atan2(point.y - other.y, point.x - other.x)

        switch type {
        case .none:
            break
        case .triangle:
            let (p1, p2, p3) = arrowheadTriangle(tip: point, angle: angle)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            path.addLine(to: p3)
            path.closeSubpath()
            context.fill(path, with: .color(color))

        case .diamond:
            let (p1, p2, p3, p4) = arrowheadDiamond(tip: point, angle: angle)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            path.addLine(to: p3)
            path.addLine(to: p4)
            path.closeSubpath()
            context.fill(path, with: .color(color))

        case .circle:
            let radius: CGFloat = 5
            let center = CGPoint(
                x: point.x - cos(angle) * radius,
                y: point.y - sin(angle) * radius
            )
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    // MARK: - Edge Label

    private static func drawLabel(
        _ label: String,
        at point: CGPoint,
        fontSize: CGFloat,
        in context: inout GraphicsContext
    ) {
        let text = Text(label)
            .font(.system(size: fontSize))
            .foregroundStyle(.secondary)

        let resolved = context.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 200, height: 30))

        // Background pill
        let padding: CGFloat = 4
        let pillRect = CGRect(
            x: point.x - textSize.width / 2 - padding,
            y: point.y - textSize.height / 2 - padding / 2,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        let pillPath = Path(roundedRect: pillRect, cornerRadius: 4)
        context.fill(pillPath, with: .color(.white.opacity(0.85)))

        // Draw text
        context.draw(resolved, at: point, anchor: .center)
    }
}
