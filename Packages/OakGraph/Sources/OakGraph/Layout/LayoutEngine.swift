import Foundation

/// Protocol for graph layout algorithms.
public protocol LayoutEngine {
    /// Compute positions for all nodes in the document.
    /// Modifies `document.nodes[*].position` in place.
    func layout(_ document: inout GraphDocument)
}
