import Foundation
import OakGraph

/// Builds LLM prompts for graph generation from document content.
struct GraphPromptBuilder {

    /// Build the system prompt instructing the LLM to produce graph JSON.
    static func systemPrompt(graphType: GraphType) -> String {
        let typeSpecific: String
        switch graphType {
        case .conceptMap:
            typeSpecific = """
            You are generating a CONCEPT MAP. Guidelines:
            - Create 8-15 nodes representing key concepts
            - Edge labels are REQUIRED — use 1-3 word verb phrases (e.g., "causes", "is part of", "leads to")
            - Do NOT set parentId on nodes (concept maps are not trees)
            """
        case .mindMap:
            typeSpecific = """
            You are generating a MIND MAP. Guidelines:
            - Create 10-25 nodes in a hierarchical tree structure
            - Exactly ONE root node must have parentId set to null
            - All other nodes MUST have parentId pointing to their parent node's id
            - Edge labels should be empty strings
            """
        }

        return """
        You are a knowledge graph generator. Given document text, produce a \(graphType == .mindMap ? "mind map" : "concept map") as JSON.

        \(typeSpecific)

        Output ONLY valid JSON (no markdown fences, no explanation):
        {
          "title": "Short descriptive title",
          "graphType": "\(graphType.rawValue)",
          "nodes": [
            {"id": "uuid-string", "label": "Concept Name", "parentId": null}
          ],
          "edges": [
            {"id": "uuid-string", "sourceId": "node-uuid", "targetId": "node-uuid", "label": "relationship"}
          ]
        }

        Rules:
        - Node labels: 2-5 words, noun phrases
        - Generate valid UUID strings for all id fields
        - Every edge sourceId/targetId MUST reference existing node ids
        - Do NOT include style, position, or size fields — they are computed automatically
        """
    }

    /// Build the user prompt with document content.
    static func userPrompt(documentText: String, graphType: GraphType) -> String {
        let truncated = String(documentText.prefix(32_000))
        let typeLabel = graphType == .mindMap ? "mind map" : "concept map"
        return "Generate a \(typeLabel) from the following document content:\n\n\(truncated)"
    }
}
