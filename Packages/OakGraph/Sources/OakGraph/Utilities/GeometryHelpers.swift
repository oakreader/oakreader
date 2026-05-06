import Foundation
import SwiftUI

// MARK: - CGPoint Math

public extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    static func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x / rhs, y: lhs.y / rhs)
    }

    static func += (lhs: inout CGPoint, rhs: CGPoint) {
        lhs.x += rhs.x
        lhs.y += rhs.y
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }

    var length: CGFloat {
        hypot(x, y)
    }

    var normalized: CGPoint {
        let len = length
        guard len > 0 else { return .zero }
        return CGPoint(x: x / len, y: y / len)
    }

    /// Clamp the length of this vector to a maximum.
    func clamped(to maxLength: CGFloat) -> CGPoint {
        let len = length
        guard len > maxLength else { return self }
        return normalized * maxLength
    }
}

// MARK: - Boundary Intersection

/// Compute the intersection point of a line from `center` to `target` with a rectangular boundary.
public func rectEdgeIntersection(center: CGPoint, size: CGSize, toward target: CGPoint) -> CGPoint {
    let dx = target.x - center.x
    let dy = target.y - center.y

    guard dx != 0 || dy != 0 else { return center }

    let hw = size.width / 2
    let hh = size.height / 2

    // Scale factor to reach the rectangle boundary
    let sx = dx != 0 ? hw / abs(dx) : .infinity
    let sy = dy != 0 ? hh / abs(dy) : .infinity
    let s = min(sx, sy)

    return CGPoint(x: center.x + dx * s, y: center.y + dy * s)
}

/// Compute the intersection of a line from `center` to `target` with an ellipse boundary.
public func ellipseEdgeIntersection(center: CGPoint, size: CGSize, toward target: CGPoint) -> CGPoint {
    let dx = target.x - center.x
    let dy = target.y - center.y

    guard dx != 0 || dy != 0 else { return center }

    let a = size.width / 2
    let b = size.height / 2
    let angle = atan2(dy, dx)

    return CGPoint(
        x: center.x + a * cos(angle),
        y: center.y + b * sin(angle)
    )
}

/// Compute the boundary intersection based on node shape.
public func nodeEdgeIntersection(node: NodeModel, toward target: CGPoint) -> CGPoint {
    switch node.style.shape {
    case .ellipse:
        return ellipseEdgeIntersection(center: node.position, size: node.size, toward: target)
    case .capsule:
        // Capsule: use ellipse approximation
        return ellipseEdgeIntersection(center: node.position, size: node.size, toward: target)
    case .rectangle, .roundedRectangle:
        return rectEdgeIntersection(center: node.position, size: node.size, toward: target)
    }
}

// MARK: - Arrowhead Geometry

/// Compute the three vertices of an arrowhead triangle pointing in the direction of `angle`.
public func arrowheadTriangle(
    tip: CGPoint,
    angle: CGFloat,
    size: CGFloat = 10,
    spread: CGFloat = .pi / 6
) -> (p1: CGPoint, p2: CGPoint, p3: CGPoint) {
    let p1 = tip
    let p2 = CGPoint(
        x: tip.x - size * cos(angle - spread),
        y: tip.y - size * sin(angle - spread)
    )
    let p3 = CGPoint(
        x: tip.x - size * cos(angle + spread),
        y: tip.y - size * sin(angle + spread)
    )
    return (p1, p2, p3)
}

/// Compute a diamond shape at a point with given angle.
public func arrowheadDiamond(
    tip: CGPoint,
    angle: CGFloat,
    size: CGFloat = 10
) -> (p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint) {
    let halfSize = size / 2
    let forward = CGPoint(x: cos(angle), y: sin(angle))
    let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
    let p1 = tip
    let p2 = CGPoint(x: tip.x - forward.x * halfSize + perpendicular.x * halfSize,
                     y: tip.y - forward.y * halfSize + perpendicular.y * halfSize)
    let p3 = CGPoint(x: tip.x - forward.x * size, y: tip.y - forward.y * size)
    let p4 = CGPoint(x: tip.x - forward.x * halfSize - perpendicular.x * halfSize,
                     y: tip.y - forward.y * halfSize - perpendicular.y * halfSize)
    return (p1, p2, p3, p4)
}

// MARK: - Bezier Helpers

/// Compute a cubic Bezier control point for a smooth curve between two points.
public func bezierControlPoints(
    from start: CGPoint,
    to end: CGPoint,
    curvature: CGFloat = 0.3
) -> (cp1: CGPoint, cp2: CGPoint) {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let cp1 = CGPoint(x: start.x + dx * curvature, y: start.y + dy * 0.0)
    let cp2 = CGPoint(x: end.x - dx * curvature, y: end.y - dy * 0.0)
    return (cp1, cp2)
}

/// Midpoint of a cubic Bezier curve (at t=0.5).
public func bezierMidpoint(start: CGPoint, cp1: CGPoint, cp2: CGPoint, end: CGPoint) -> CGPoint {
    let t: CGFloat = 0.5
    let mt = 1 - t
    let x = mt * mt * mt * start.x + 3 * mt * mt * t * cp1.x + 3 * mt * t * t * cp2.x + t * t * t * end.x
    let y = mt * mt * mt * start.y + 3 * mt * mt * t * cp1.y + 3 * mt * t * t * cp2.y + t * t * t * end.y
    return CGPoint(x: x, y: y)
}

// MARK: - Color Helpers

public extension Color {
    /// Create a Color from a hex string like "#FF6666" or "FF6666".
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (128, 128, 128)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}
