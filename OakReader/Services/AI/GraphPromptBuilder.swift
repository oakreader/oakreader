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
            - Create 8-20 nodes representing key concepts
            - Edge labels are REQUIRED — use 1-3 word verb phrases (e.g., "causes", "is part of", "leads to")
            - Do NOT set parentId on nodes (concept maps are not trees)
            - Use "bezier" lineType and "triangle" targetArrow for edges
            - Use varied fillColorHex values from this palette for different concept clusters:
              "#E3F2FD", "#F3E5F5", "#E8F5E9", "#FFF3E0", "#FCE4EC", "#E0F7FA", "#FFF9C4", "#F1F8E9"
            """
        case .mindMap:
            typeSpecific = """
            You are generating a MIND MAP. Guidelines:
            - Create 10-30 nodes in a hierarchical tree structure
            - Exactly ONE root node must have parentId set to null
            - All other nodes MUST have parentId pointing to their parent node's id
            - Edge labels should be empty strings (mind maps don't label edges)
            - Use "bezier" lineType, "none" for both sourceArrow and targetArrow
            - Use varied fillColorHex values for different branches
            """
        }

        return """
        You are a knowledge graph generator. Given document text, produce a \(graphType == .mindMap ? "mind map" : "concept map") as JSON.

        \(typeSpecific)

        Output ONLY valid JSON matching this exact schema (no markdown fences, no explanation):
        {
          "title": "Short descriptive title",
          "graphType": "\(graphType.rawValue)",
          "nodes": [
            {
              "id": "uuid-string",
              "label": "2-5 word concept",
              "style": {
                "shape": "roundedRectangle",
                "fillColorHex": "#E3F2FD",
                "borderColorHex": "#1976D2",
                "borderWidth": 1.5,
                "cornerRadius": 8,
                "shadowRadius": 2,
                "textStyle": {
                  "fontName": "system",
                  "fontSize": 14,
                  "colorHex": "#333333",
                  "isBold": false
                }
              },
              "parentId": null
            }
          ],
          "edges": [
            {
              "id": "uuid-string",
              "sourceId": "must-match-a-node-id",
              "targetId": "must-match-a-node-id",
              "label": "relationship verb",
              "style": {
                "lineType": "bezier",
                "sourceArrow": "none",
                "targetArrow": "triangle",
                "isDashed": false,
                "colorHex": "#666666",
                "thickness": 1.5,
                "labelFontSize": 11
              }
            }
          ]
        }

        Rules:
        - Node labels: 2-5 words, noun phrases capturing key concepts
        - Make the root/central node bold (isBold: true) with a slightly larger fontSize (16)
        - Generate valid UUID strings for all id fields
        - Every edge's sourceId and targetId MUST reference existing node ids
        - Position and size fields are optional and will be computed by the layout engine
        """
    }

    /// Build the user prompt with document content.
    static func userPrompt(documentText: String, graphType: GraphType) -> String {
        let truncated = String(documentText.prefix(32_000))
        let typeLabel = graphType == .mindMap ? "mind map" : "concept map"
        return "Generate a \(typeLabel) from the following document content:\n\n\(truncated)"
    }
}
