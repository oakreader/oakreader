import Foundation
import SwiftUI

/// Line rendering type for edges.
public enum EdgeLineType: String, Codable, Sendable, CaseIterable {
    case straight
    case bezier
    case orthogonal
}

/// Arrowhead shape at edge endpoints.
public enum ArrowHead: String, Codable, Sendable, CaseIterable {
    case none
    case triangle
    case diamond
    case circle
}

/// Visual style for an edge.
public struct EdgeStyle: Codable, Sendable, Hashable {
    public var lineType: EdgeLineType
    public var sourceArrow: ArrowHead
    public var targetArrow: ArrowHead
    public var isDashed: Bool
    public var colorHex: String
    public var thickness: CGFloat
    public var labelFontSize: CGFloat

    public init(
        lineType: EdgeLineType = .bezier,
        sourceArrow: ArrowHead = .none,
        targetArrow: ArrowHead = .triangle,
        isDashed: Bool = false,
        colorHex: String = "#666666",
        thickness: CGFloat = 1.5,
        labelFontSize: CGFloat = 11
    ) {
        self.lineType = lineType
        self.sourceArrow = sourceArrow
        self.targetArrow = targetArrow
        self.isDashed = isDashed
        self.colorHex = colorHex
        self.thickness = thickness
        self.labelFontSize = labelFontSize
    }

    public static let `default` = EdgeStyle()

    /// Style for mind map edges (no arrowheads, curved).
    public static let mindMap = EdgeStyle(
        lineType: .bezier,
        sourceArrow: .none,
        targetArrow: .none,
        colorHex: "#999999",
        thickness: 2
    )
}
