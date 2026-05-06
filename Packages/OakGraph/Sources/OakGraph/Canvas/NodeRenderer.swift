import SwiftUI

/// Draws nodes on a SwiftUI Canvas context.
public struct NodeRenderer {

    /// Draw a single node.
    public static func draw(
        node: NodeModel,
        isSelected: Bool,
        in context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        let bounds = node.bounds
        let style = node.style

        // Build the shape path
        let shapePath = Self.buildShapePath(for: style, in: bounds)

        // Shadow layer
        if style.shadowRadius > 0 {
            context.drawLayer { shadowCtx in
                shadowCtx.addFilter(.shadow(
                    color: .black.opacity(0.15),
                    radius: style.shadowRadius,
                    x: 0,
                    y: style.shadowRadius / 2
                ))
                shadowCtx.fill(shapePath, with: .color(Color(hex: style.fillColorHex)))
            }
        } else {
            // Fill
            context.fill(shapePath, with: .color(Color(hex: style.fillColorHex)))
        }

        // Border
        if style.borderWidth > 0 {
            context.stroke(
                shapePath,
                with: .color(Color(hex: style.borderColorHex)),
                lineWidth: style.borderWidth
            )
        }

        // Selection ring
        if isSelected {
            let selectionPath = Self.buildShapePath(
                for: style,
                in: bounds.insetBy(dx: -3, dy: -3)
            )
            context.stroke(
                selectionPath,
                with: .color(.accentColor),
                lineWidth: 2
            )
        }

        // Label text
        let textColor = Color(hex: style.textStyle.colorHex)
        let font: Font = style.textStyle.isBold
            ? .system(size: style.textStyle.fontSize, weight: .semibold)
            : .system(size: style.textStyle.fontSize)

        let text = Text(node.label)
            .font(font)
            .foregroundStyle(textColor)

        let resolved = context.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: bounds.width - 8, height: bounds.height))
        let textOrigin = CGPoint(
            x: node.position.x - textSize.width / 2,
            y: node.position.y - textSize.height / 2
        )
        context.draw(resolved, at: textOrigin, anchor: .topLeading)
    }

    /// Build the shape `Path` for a given style and bounds.
    private static func buildShapePath(for style: NodeStyle, in rect: CGRect) -> Path {
        switch style.shape {
        case .rectangle:
            return Path(rect)
        case .roundedRectangle:
            return Path(roundedRect: rect, cornerRadius: style.cornerRadius)
        case .ellipse:
            return Path(ellipseIn: rect)
        case .capsule:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
        }
    }
}
