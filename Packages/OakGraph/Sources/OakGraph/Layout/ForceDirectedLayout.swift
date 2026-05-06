import Foundation
import SwiftUI

/// Force-directed layout for concept maps using spring-electric simulation.
///
/// Based on Fruchterman-Reingold algorithm:
/// - Repulsive force between all node pairs (Coulomb's law)
/// - Attractive force along edges (Hooke's law)
/// - Temperature-based cooling schedule
public struct ForceDirectedLayout: LayoutEngine {
    /// Number of simulation iterations.
    public var iterations: Int = 300
    /// Cooling factor applied each iteration.
    public var coolingFactor: CGFloat = 0.95

    public init(iterations: Int = 300, coolingFactor: CGFloat = 0.95) {
        self.iterations = iterations
        self.coolingFactor = coolingFactor
    }

    public func layout(_ document: inout GraphDocument) {
        let nodeCount = document.nodes.count
        guard nodeCount > 1 else {
            if nodeCount == 1 {
                document.nodes[0].position = CGPoint(
                    x: document.canvasSize.width / 2,
                    y: document.canvasSize.height / 2
                )
            }
            return
        }

        document.autoSizeAllNodes()

        let area = document.canvasSize.width * document.canvasSize.height
        let k = sqrt(area / CGFloat(nodeCount)) // Optimal distance
        let kSquared = k * k
        var temperature = document.canvasSize.width / 10

        // Initialize positions in a circle around center
        let center = CGPoint(x: document.canvasSize.width / 2, y: document.canvasSize.height / 2)
        let radius = min(document.canvasSize.width, document.canvasSize.height) / 4
        for i in document.nodes.indices {
            let angle = 2 * .pi * CGFloat(i) / CGFloat(nodeCount)
            document.nodes[i].position = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
        }

        // Build edge lookup for O(1) access
        let edgePairs = document.edges.compactMap { edge -> (Int, Int)? in
            guard let si = document.nodeIndex(withId: edge.sourceId),
                  let ti = document.nodeIndex(withId: edge.targetId) else { return nil }
            return (si, ti)
        }

        // Simulation loop
        for _ in 0..<iterations {
            var displacements = [CGPoint](repeating: .zero, count: nodeCount)

            // Repulsive forces between all pairs
            for i in 0..<nodeCount {
                for j in (i + 1)..<nodeCount {
                    let delta = document.nodes[i].position - document.nodes[j].position
                    var dist = delta.length
                    if dist < 1 { dist = 1 } // Avoid division by zero

                    let force = kSquared / dist
                    let direction = delta.normalized
                    let displacement = direction * force

                    displacements[i] += displacement
                    displacements[j] = displacements[j] - displacement
                }
            }

            // Attractive forces along edges
            for (si, ti) in edgePairs {
                let delta = document.nodes[si].position - document.nodes[ti].position
                var dist = delta.length
                if dist < 1 { dist = 1 }

                let force = (dist * dist) / k
                let direction = delta.normalized
                let displacement = direction * force

                displacements[si] = displacements[si] - displacement
                displacements[ti] += displacement
            }

            // Apply displacements with temperature clamping
            for i in 0..<nodeCount {
                let disp = displacements[i]
                let dispLen = disp.length
                guard dispLen > 0 else { continue }

                let clamped = disp.clamped(to: temperature)
                document.nodes[i].position += clamped

                // Keep within canvas bounds (with margin)
                let margin: CGFloat = 50
                document.nodes[i].position.x = min(
                    document.canvasSize.width - margin,
                    max(margin, document.nodes[i].position.x)
                )
                document.nodes[i].position.y = min(
                    document.canvasSize.height - margin,
                    max(margin, document.nodes[i].position.y)
                )
            }

            temperature *= coolingFactor
        }
    }
}
