import Foundation
import SwiftUI

/// Available node shapes.
public enum NodeShape: String, Codable, Sendable, CaseIterable {
    case rectangle
    case roundedRectangle
    case ellipse
    case capsule
}

/// Text styling for node labels.
public struct TextStyle: Codable, Sendable, Hashable {
    public var fontName: String
    public var fontSize: CGFloat
    public var colorHex: String
    public var isBold: Bool

    public init(
        fontName: String = "system",
        fontSize: CGFloat = 14,
        colorHex: String = "#333333",
        isBold: Bool = false
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.isBold = isBold
    }

    public static let `default` = TextStyle()
}

/// Visual style for a node.
public struct NodeStyle: Codable, Sendable, Hashable {
    public var shape: NodeShape
    public var fillColorHex: String
    public var borderColorHex: String
    public var borderWidth: CGFloat
    public var cornerRadius: CGFloat
    public var shadowRadius: CGFloat
    public var textStyle: TextStyle

    public init(
        shape: NodeShape = .roundedRectangle,
        fillColorHex: String = "#E3F2FD",
        borderColorHex: String = "#1976D2",
        borderWidth: CGFloat = 1.5,
        cornerRadius: CGFloat = 8,
        shadowRadius: CGFloat = 2,
        textStyle: TextStyle = .default
    ) {
        self.shape = shape
        self.fillColorHex = fillColorHex
        self.borderColorHex = borderColorHex
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.textStyle = textStyle
    }

    public static let `default` = NodeStyle()
}
