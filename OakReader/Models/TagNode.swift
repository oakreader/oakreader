import Foundation

/// A node in the tag hierarchy tree. Supports slash-separated tag names (e.g. "Research/AI").
struct TagNode: Identifiable {
    let id: UUID
    let name: String       // This segment only (e.g. "AI")
    let fullPath: String   // Full path (e.g. "Research/AI")
    let option: PropertyOption?  // Non-nil for leaf/concrete tags
    var count: Int         // Direct item count for this tag
    var children: [TagNode]

    /// Total count including all descendants.
    func totalCount() -> Int {
        count + children.reduce(0) { $0 + $1.totalCount() }
    }

    /// Build a hierarchy from flat (option, count) pairs using slash separators.
    static func buildHierarchy(from pairs: [(option: PropertyOption, count: Int)]) -> [TagNode] {
        var root: [TagNode] = []

        for (option, count) in pairs {
            let segments = option.name.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            insertInto(nodes: &root, segments: segments, index: 0, option: option, count: count)
        }

        sortByCount(&root)
        return root
    }

    private static func insertInto(nodes: inout [TagNode], segments: [String], index: Int, option: PropertyOption, count: Int) {
        let segment = segments[index]
        let pathSoFar = segments[0...index].joined(separator: "/")
        let isLeaf = index == segments.count - 1

        if let existing = nodes.firstIndex(where: { $0.name == segment }) {
            if isLeaf {
                // This node becomes a concrete tag
                nodes[existing] = TagNode(
                    id: option.id,
                    name: segment,
                    fullPath: pathSoFar,
                    option: option,
                    count: count,
                    children: nodes[existing].children
                )
            } else {
                insertInto(nodes: &nodes[existing].children, segments: segments, index: index + 1, option: option, count: count)
            }
        } else {
            if isLeaf {
                nodes.append(TagNode(
                    id: option.id,
                    name: segment,
                    fullPath: pathSoFar,
                    option: option,
                    count: count,
                    children: []
                ))
            } else {
                // Intermediate-only node
                var intermediate = TagNode(
                    id: UUID(),
                    name: segment,
                    fullPath: pathSoFar,
                    option: nil,
                    count: 0,
                    children: []
                )
                insertInto(nodes: &intermediate.children, segments: segments, index: index + 1, option: option, count: count)
                nodes.append(intermediate)
            }
        }
    }

    private static func sortByCount(_ nodes: inout [TagNode]) {
        nodes.sort { $0.totalCount() > $1.totalCount() }
        for i in nodes.indices {
            sortByCount(&nodes[i].children)
        }
    }
}
