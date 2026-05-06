import Foundation
import SwiftUI

/// A node in the graph.
public struct NodeModel: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var label: String
    public var position: CGPoint
    public var size: CGSize
    public var style: NodeStyle
    /// Parent node ID for tree structures (mind maps).
    public var parentId: UUID?

    public init(
        id: UUID = UUID(),
        label: String,
        position: CGPoint = .zero,
        size: CGSize = CGSize(width: 120, height: 40),
        style: NodeStyle = .default,
        parentId: UUID? = nil
    ) {
        self.id = id
        self.label = label
        self.position = position
        self.size = size
        self.style = style
        self.parentId = parentId
    }

    /// The bounding rectangle of the node centered at `position`.
    public var bounds: CGRect {
        CGRect(
            x: position.x - size.width / 2,
            y: position.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Compute node size based on label text length.
    public mutating func autoSize() {
        let charWidth: CGFloat = style.textStyle.isBold ? 9 : 8
        let textWidth = CGFloat(label.count) * charWidth * (style.textStyle.fontSize / 14)
        let padding: CGFloat = 32
        let width = max(80, min(textWidth + padding, 240))
        let height: CGFloat = style.textStyle.fontSize + 24
        size = CGSize(width: width, height: height)
    }
}

