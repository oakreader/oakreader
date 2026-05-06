import Foundation
import SwiftUI

/// Hit testing utilities for detecting which node/edge was tapped.
public struct HitTesting {

    /// Find the node at a given canvas-coordinate point, or nil.
    /// Nodes are checked in reverse order (top-most first).
    public static func nodeAt(point: CGPoint, in document: GraphDocument) -> UUID? {
        for node in document.nodes.reversed() {
            if node.bounds.contains(point) {
                return node.id
            }
        }
        return nil
    }

    /// Find the edge nearest to a given canvas-coordinate point within `tolerance`, or nil.
    public static func edgeAt(
        point: CGPoint,
        in document: GraphDocument,
        tolerance: CGFloat = 8
    ) -> UUID? {
        var closest: (id: UUID, distance: CGFloat)?

        for edge in document.edges {
            guard let source = document.node(withId: edge.sourceId),
                  let target = document.node(withId: edge.targetId) else { continue }

            let start = nodeEdgeIntersection(node: source, toward: target.position)
            let end = nodeEdgeIntersection(node: target, toward: source.position)

            let dist: CGFloat
            switch edge.style.lineType {
            case .straight, .orthogonal:
                dist = pointToSegmentDistance(point: point, segStart: start, segEnd: end)
            case .bezier:
                let (cp1, cp2) = bezierControlPoints(from: start, to: end)
                dist = pointToBezierDistance(point: point, start: start, cp1: cp1, cp2: cp2, end: end)
            }

            if dist <= tolerance {
                if closest == nil || dist < closest!.distance {
                    closest = (edge.id, dist)
                }
            }
        }

        return closest?.id
    }

    // MARK: - Distance Calculations

    /// Distance from a point to a line segment.
    private static func pointToSegmentDistance(point: CGPoint, segStart: CGPoint, segEnd: CGPoint) -> CGFloat {
        let dx = segEnd.x - segStart.x
        let dy = segEnd.y - segStart.y
        let lengthSq = dx * dx + dy * dy

        guard lengthSq > 0 else {
            return point.distance(to: segStart)
        }

        var t = ((point.x - segStart.x) * dx + (point.y - segStart.y) * dy) / lengthSq
        t = max(0, min(1, t))

        let projection = CGPoint(x: segStart.x + t * dx, y: segStart.y + t * dy)
        return point.distance(to: projection)
    }

    /// Approximate distance from a point to a cubic Bezier curve (sample 20 segments).
    private static func pointToBezierDistance(
        point: CGPoint,
        start: CGPoint,
        cp1: CGPoint,
        cp2: CGPoint,
        end: CGPoint,
        samples: Int = 20
    ) -> CGFloat {
        var minDist: CGFloat = .infinity

        for i in 0..<samples {
            let t0 = CGFloat(i) / CGFloat(samples)
            let t1 = CGFloat(i + 1) / CGFloat(samples)
            let p0 = bezierPoint(t: t0, start: start, cp1: cp1, cp2: cp2, end: end)
            let p1 = bezierPoint(t: t1, start: start, cp1: cp1, cp2: cp2, end: end)
            let dist = pointToSegmentDistance(point: point, segStart: p0, segEnd: p1)
            minDist = min(minDist, dist)
        }

        return minDist
    }

    /// Evaluate a cubic Bezier at parameter t.
    private static func bezierPoint(
        t: CGFloat,
        start: CGPoint,
        cp1: CGPoint,
        cp2: CGPoint,
        end: CGPoint
    ) -> CGPoint {
        let mt = 1 - t
        let x = mt * mt * mt * start.x + 3 * mt * mt * t * cp1.x + 3 * mt * t * t * cp2.x + t * t * t * end.x
        let y = mt * mt * mt * start.y + 3 * mt * mt * t * cp1.y + 3 * mt * t * t * cp2.y + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }
}
