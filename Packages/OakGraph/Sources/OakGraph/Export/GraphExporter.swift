import SwiftUI
import AppKit

/// Exports a GraphDocument to PNG, SVG, or JSON formats.
public struct GraphExporter {

    public init() {}

    // MARK: - JSON

    /// Export graph as JSON data.
    public func exportJSON(_ document: GraphDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    // MARK: - PNG

    /// Export graph as PNG data using ImageRenderer.
    @MainActor
    public func exportPNG(_ document: GraphDocument, scale: CGFloat = 2.0) -> Data? {
        let bounds = computeBounds(document)
        let padding: CGFloat = 40
        let width = bounds.width + padding * 2
        let height = bounds.height + padding * 2
        let offsetX = -bounds.minX + padding
        let offsetY = -bounds.minY + padding

        let view = Canvas { context, size in
            context.translateBy(x: offsetX, y: offsetY)

            // Draw edges
            for edge in document.edges {
                guard let source = document.node(withId: edge.sourceId),
                      let target = document.node(withId: edge.targetId) else { continue }
                EdgeRenderer.draw(
                    edge: edge, source: source, target: target,
                    isSelected: false, in: &context, canvasSize: size
                )
            }

            // Draw nodes
            for node in document.nodes {
                NodeRenderer.draw(
                    node: node, isSelected: false,
                    in: &context, canvasSize: size
                )
            }
        }
        .frame(width: width, height: height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = scale

        guard let nsImage = renderer.nsImage else { return nil }
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - SVG

    /// Export graph as SVG string.
    public func exportSVG(_ document: GraphDocument) -> String {
        let bounds = computeBounds(document)
        let padding: CGFloat = 40
        let width = bounds.width + padding * 2
        let height = bounds.height + padding * 2
        let offsetX = -bounds.minX + padding
        let offsetY = -bounds.minY + padding

        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(width))" height="\(Int(height))" viewBox="0 0 \(Int(width)) \(Int(height))">
          <defs>
            <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
              <polygon points="0 0, 10 3.5, 0 7" fill="#666666"/>
            </marker>
          </defs>
          <rect width="100%" height="100%" fill="white"/>
          <g transform="translate(\(offsetX), \(offsetY))">

        """

        // Edges
        for edge in document.edges {
            guard let source = document.node(withId: edge.sourceId),
                  let target = document.node(withId: edge.targetId) else { continue }

            let start = nodeEdgeIntersection(node: source, toward: target.position)
            let end = nodeEdgeIntersection(node: target, toward: source.position)

            let strokeColor = edge.style.colorHex.hasPrefix("#") ? edge.style.colorHex : "#\(edge.style.colorHex)"
            let dashArray = edge.style.isDashed ? " stroke-dasharray=\"8 4\"" : ""
            let markerEnd = edge.style.targetArrow != .none ? " marker-end=\"url(#arrowhead)\"" : ""

            switch edge.style.lineType {
            case .straight, .orthogonal:
                svg += "    <line x1=\"\(start.x)\" y1=\"\(start.y)\" x2=\"\(end.x)\" y2=\"\(end.y)\" stroke=\"\(strokeColor)\" stroke-width=\"\(edge.style.thickness)\"\(dashArray)\(markerEnd)/>\n"
            case .bezier:
                let (cp1, cp2) = bezierControlPoints(from: start, to: end)
                svg += "    <path d=\"M \(start.x) \(start.y) C \(cp1.x) \(cp1.y), \(cp2.x) \(cp2.y), \(end.x) \(end.y)\" fill=\"none\" stroke=\"\(strokeColor)\" stroke-width=\"\(edge.style.thickness)\"\(dashArray)\(markerEnd)/>\n"
            }

            // Edge label
            if !edge.label.isEmpty {
                let mx = (start.x + end.x) / 2
                let my = (start.y + end.y) / 2
                svg += "    <text x=\"\(mx)\" y=\"\(my - 4)\" text-anchor=\"middle\" font-size=\"\(edge.style.labelFontSize)\" fill=\"#666666\">\(escapeXML(edge.label))</text>\n"
            }
        }

        // Nodes
        for node in document.nodes {
            let b = node.bounds
            let fillColor = node.style.fillColorHex.hasPrefix("#") ? node.style.fillColorHex : "#\(node.style.fillColorHex)"
            let borderColor = node.style.borderColorHex.hasPrefix("#") ? node.style.borderColorHex : "#\(node.style.borderColorHex)"

            switch node.style.shape {
            case .rectangle:
                svg += "    <rect x=\"\(b.minX)\" y=\"\(b.minY)\" width=\"\(b.width)\" height=\"\(b.height)\" fill=\"\(fillColor)\" stroke=\"\(borderColor)\" stroke-width=\"\(node.style.borderWidth)\"/>\n"
            case .roundedRectangle:
                svg += "    <rect x=\"\(b.minX)\" y=\"\(b.minY)\" width=\"\(b.width)\" height=\"\(b.height)\" rx=\"\(node.style.cornerRadius)\" fill=\"\(fillColor)\" stroke=\"\(borderColor)\" stroke-width=\"\(node.style.borderWidth)\"/>\n"
            case .ellipse, .capsule:
                svg += "    <ellipse cx=\"\(node.position.x)\" cy=\"\(node.position.y)\" rx=\"\(b.width / 2)\" ry=\"\(b.height / 2)\" fill=\"\(fillColor)\" stroke=\"\(borderColor)\" stroke-width=\"\(node.style.borderWidth)\"/>\n"
            }

            // Label
            let textColor = node.style.textStyle.colorHex.hasPrefix("#") ? node.style.textStyle.colorHex : "#\(node.style.textStyle.colorHex)"
            let fontWeight = node.style.textStyle.isBold ? " font-weight=\"bold\"" : ""
            svg += "    <text x=\"\(node.position.x)\" y=\"\(node.position.y + node.style.textStyle.fontSize / 3)\" text-anchor=\"middle\" font-size=\"\(node.style.textStyle.fontSize)\"\(fontWeight) fill=\"\(textColor)\">\(escapeXML(node.label))</text>\n"
        }

        svg += """
          </g>
        </svg>
        """
        return svg
    }

    // MARK: - Thumbnail

    /// Export a small thumbnail PNG of the graph for list previews.
    @MainActor
    public func exportThumbnail(_ document: GraphDocument, targetSize: CGSize = CGSize(width: 320, height: 200)) -> Data? {
        let bounds = computeBounds(document)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let padding: CGFloat = 20
        let contentWidth = bounds.width + padding * 2
        let contentHeight = bounds.height + padding * 2

        // Fit content into target size
        let scaleX = targetSize.width / contentWidth
        let scaleY = targetSize.height / contentHeight
        let fitScale = min(scaleX, scaleY, 1.0) // don't upscale

        let width = contentWidth * fitScale
        let height = contentHeight * fitScale
        let offsetX = (-bounds.minX + padding) * fitScale
        let offsetY = (-bounds.minY + padding) * fitScale

        let view = Canvas { context, size in
            // White background
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            context.scaleBy(x: fitScale, y: fitScale)
            context.translateBy(x: (-bounds.minX + padding), y: (-bounds.minY + padding))

            // Draw edges
            for edge in document.edges {
                guard let source = document.node(withId: edge.sourceId),
                      let target = document.node(withId: edge.targetId) else { continue }
                EdgeRenderer.draw(
                    edge: edge, source: source, target: target,
                    isSelected: false, in: &context, canvasSize: size
                )
            }

            // Draw nodes
            for node in document.nodes {
                NodeRenderer.draw(
                    node: node, isSelected: false,
                    in: &context, canvasSize: size
                )
            }
        }
        .frame(width: width, height: height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0 // 1x for speed

        guard let nsImage = renderer.nsImage else { return nil }
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Helpers

    /// Compute the bounding rectangle of all nodes.
    private func computeBounds(_ document: GraphDocument) -> CGRect {
        guard let first = document.nodes.first else {
            return CGRect(origin: .zero, size: document.canvasSize)
        }

        var minX = first.bounds.minX
        var minY = first.bounds.minY
        var maxX = first.bounds.maxX
        var maxY = first.bounds.maxY

        for node in document.nodes.dropFirst() {
            minX = min(minX, node.bounds.minX)
            minY = min(minY, node.bounds.minY)
            maxX = max(maxX, node.bounds.maxX)
            maxY = max(maxY, node.bounds.maxY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
