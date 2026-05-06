# OakGraph: Native SwiftUI Concept Map & Mind Map

## Overview

OakGraph is a standalone SPM package (`Packages/OakGraph/`) that provides concept map and mind map rendering, layout, and interaction using native SwiftUI `Canvas`. It integrates into OakReader as a right-panel plugin following the same pattern as Notes and Translation.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    OakReader App                     │
│                                                      │
│  ┌──────────────┐  ┌───────────────┐  ┌───────────┐ │
│  │ GraphService  │  │GraphViewModel │  │ GraphPanel│ │
│  │ (GRDB + I/O)  │──│ (@Observable) │──│ (SwiftUI) │ │
│  └──────────────┘  └───────┬───────┘  └───────────┘ │
│                            │                         │
│  ┌─────────────────────────┴──────────────────────┐  │
│  │              OakGraph Package                   │  │
│  │                                                 │  │
│  │  ┌─────────┐  ┌──────────┐  ┌───────────────┐  │  │
│  │  │ Models  │  │ Layout   │  │ Canvas View   │  │  │
│  │  │ Graph   │  │ Tree     │  │ NodeRenderer  │  │  │
│  │  │ Node    │  │ Force    │  │ EdgeRenderer  │  │  │
│  │  │ Edge    │  │ Directed │  │ HitTesting    │  │  │
│  │  │ Styles  │  │          │  │ Interaction   │  │  │
│  │  └─────────┘  └──────────┘  └───────────────┘  │  │
│  │                                                 │  │
│  │  ┌──────────────────────────────────────────┐   │  │
│  │  │           GraphExporter                  │   │  │
│  │  │           PNG / SVG / JSON               │   │  │
│  │  └──────────────────────────────────────────┘   │  │
│  └─────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Package Structure

```
Packages/OakGraph/
├── Package.swift
└── Sources/OakGraph/
    ├── Models/
    │   ├── GraphDocument.swift      # Top-level container
    │   ├── NodeModel.swift          # Node data + position
    │   ├── EdgeModel.swift          # Edge data (source → target)
    │   ├── NodeStyle.swift          # Shape, colors, text style
    │   ├── EdgeStyle.swift          # Line type, arrows, dashed
    │   └── GraphType.swift          # .mindMap | .conceptMap
    ├── Layout/
    │   ├── LayoutEngine.swift       # Protocol
    │   ├── TreeLayout.swift         # Reingold-Tilford (mind maps)
    │   └── ForceDirectedLayout.swift # Spring-electric (concept maps)
    ├── Canvas/
    │   ├── GraphCanvasView.swift    # Main SwiftUI Canvas view
    │   ├── NodeRenderer.swift       # Draw nodes on Canvas
    │   └── EdgeRenderer.swift       # Draw edges on Canvas
    ├── Interaction/
    │   ├── GraphInteractionState.swift # @Observable zoom/pan/selection
    │   └── HitTesting.swift         # Point-in-node, point-near-edge
    ├── Export/
    │   └── GraphExporter.swift      # PNG, SVG, JSON export
    └── Utilities/
        └── GeometryHelpers.swift    # CGPoint math, Bezier, arrows
```

## Data Models

### GraphDocument

Top-level container. This is what the LLM produces and what gets serialized to disk.

```swift
struct GraphDocument: Codable, Sendable {
    let id: UUID
    var title: String
    var graphType: GraphType
    var nodes: [NodeModel]
    var edges: [EdgeModel]
    var canvasSize: CGSize           // default 2000×2000
}
```

### NodeModel

Each node has a position in canvas coordinates. The `parentId` field is only used for mind maps (tree structure).

```swift
struct NodeModel: Identifiable, Codable, Sendable {
    let id: UUID
    var label: String               // 2-5 words
    var position: CGPoint           // canvas coordinates
    var size: CGSize                // auto-computed from text
    var style: NodeStyle
    var parentId: UUID?             // tree parent (mind maps only)
}
```

### EdgeModel

Directed edge from source to target. Label is used for concept maps ("causes", "is part of").

```swift
struct EdgeModel: Identifiable, Codable, Sendable {
    let id: UUID
    var sourceId: UUID
    var targetId: UUID
    var label: String
    var style: EdgeStyle
}
```

### Styling

```swift
enum NodeShape: String, Codable, Sendable, CaseIterable {
    case rectangle, roundedRectangle, ellipse, capsule
}

struct TextStyle: Codable, Sendable {
    var fontName: String            // "system" or specific font
    var fontSize: CGFloat           // 12-18
    var colorHex: String            // "#333333"
    var isBold: Bool
}

struct NodeStyle: Codable, Sendable {
    var shape: NodeShape
    var fillColorHex: String        // "#E3F2FD"
    var borderColorHex: String      // "#1976D2"
    var borderWidth: CGFloat        // 1-3
    var cornerRadius: CGFloat       // 8-12
    var shadowRadius: CGFloat       // 0-4
    var textStyle: TextStyle
}

enum EdgeLineType: String, Codable, Sendable, CaseIterable {
    case straight, bezier, orthogonal
}

enum ArrowHead: String, Codable, Sendable, CaseIterable {
    case none, triangle, diamond, circle
}

struct EdgeStyle: Codable, Sendable {
    var lineType: EdgeLineType
    var sourceArrow: ArrowHead
    var targetArrow: ArrowHead
    var isDashed: Bool
    var colorHex: String            // "#666666"
    var thickness: CGFloat          // 1-3
    var labelFontSize: CGFloat      // 10-12
}

enum GraphType: String, Codable, Sendable, CaseIterable {
    case mindMap
    case conceptMap
}
```

## Layout Engines

### Protocol

```swift
protocol LayoutEngine {
    func layout(_ document: inout GraphDocument)
}
```

### TreeLayout (Mind Maps)

Uses Reingold-Tilford algorithm:
1. Find root node (node with no parentId, or first node)
2. First pass: compute subtree widths bottom-up
3. Second pass: assign positions top-down, centering children under parents
4. Root placed at center of canvas

Parameters:
- Horizontal spacing: 60pt between sibling nodes
- Vertical spacing: 80pt between levels
- Root radiates outward (left subtrees go left, right subtrees go right)

### ForceDirectedLayout (Concept Maps)

Spring-electric force simulation:

```
For each iteration (300 total):
    For each node pair (i, j):
        repulsive_force = k² / distance(i, j)          # Coulomb
    For each edge (u, v):
        attractive_force = distance(u, v)² / k          # Hooke
    For each node:
        position += clamped(net_force × temperature)
    temperature *= 0.95                                  # cooling
```

Parameters:
- `k` = optimal distance = sqrt(canvasArea / nodeCount)
- Initial temperature: canvasWidth / 10
- Max displacement per step: clamped to temperature
- Iterations: 300

Reference: Heimer uses simulated annealing with grid-based constraint solving (overlap cost + connection cost). Our approach is simpler but effective for <100 nodes.

## Canvas Rendering

### GraphCanvasView

Main SwiftUI view combining Canvas + gesture handlers:

```swift
struct GraphCanvasView: View {
    @Bindable var interaction: GraphInteractionState
    let document: GraphDocument
    var onNodeMoved: ((UUID, CGPoint) -> Void)?
    var onNodeSelected: ((UUID?) -> Void)?
    var onNodeDoubleTapped: ((UUID) -> Void)?
    var onDeleteRequested: (() -> Void)?

    var body: some View {
        ZStack {
            Canvas { context, size in
                // Apply zoom + pan transform
                // Draw edges first (behind nodes)
                // Draw nodes on top
            }
            // TextField overlay for inline editing
        }
        .gesture(dragGesture)
        .gesture(magnificationGesture)
        .onKeyPress(.delete) { ... }
    }
}
```

### NodeRenderer

Draws a single node on Canvas:

1. **Shape**: Resolved from `NodeStyle.shape` → Path
2. **Shadow**: `context.drawLayer` with shadow applied
3. **Fill**: `context.fill(path, with: .color(fillColor))`
4. **Border**: `context.stroke(path, with: .color(borderColor))`
5. **Label**: `context.draw(resolvedText, at: center)`
6. **Selection ring**: Blue accent stroke if selected

### EdgeRenderer

Draws a single edge on Canvas:

1. **Path**: Straight line or Bezier curve between node edge points
2. **Dashed**: Apply `StrokeStyle(dash: [8, 4])` if `isDashed`
3. **Arrowheads**: Small triangles at endpoints
4. **Label**: Resolved text at path midpoint, with white background pill

### Connection Points

Edges connect at the intersection of the edge line with the node boundary (not center):
- For rectangles: compute line-rect intersection
- For ellipses: compute line-ellipse intersection
- This prevents edges from overlapping with node shapes

## Interaction

### GraphInteractionState

```swift
@Observable
class GraphInteractionState {
    var scale: CGFloat = 1.0            // 0.25 to 4.0
    var offset: CGPoint = .zero         // pan offset
    var selectedNodeId: UUID?
    var selectedEdgeId: UUID?
    var draggingNodeId: UUID?
    var dragOffset: CGSize = .zero
    var editingNodeId: UUID?            // inline text editing
    var editingText: String = ""
}
```

### Gesture Handling

| Gesture | Target | Action |
|---------|--------|--------|
| Tap | Node | Select node |
| Tap | Empty | Deselect all |
| Drag | Node | Move node position |
| Drag | Empty | Pan canvas |
| Magnify | Canvas | Zoom (0.25x - 4.0x) |
| Double-tap | Node | Enter inline text edit |
| Delete key | Any | Remove selected node/edge |

### Hit Testing

```swift
struct HitTesting {
    static func nodeAt(point: CGPoint, in document: GraphDocument) -> UUID?
    static func edgeAt(point: CGPoint, in document: GraphDocument, tolerance: CGFloat) -> UUID?
}
```

- **Node**: Check if point is inside node rect (position ± size/2)
- **Edge**: Check if point is within `tolerance` (8pt) of edge path

## Export

### PNG Export

```swift
func exportPNG(document: GraphDocument, scale: CGFloat = 2.0) -> Data? {
    let renderer = ImageRenderer(content: renderView)
    renderer.scale = scale
    guard let image = renderer.nsImage else { return nil }
    return image.tiffRepresentation?.bitmap?.pngData
}
```

### SVG Export

Template-based XML generation:

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="W" height="H">
  <!-- Edges -->
  <line x1="..." y1="..." x2="..." y2="..." stroke="..." />
  <path d="M... C..." stroke="..." />  <!-- Bezier -->
  <!-- Arrowhead markers -->
  <defs><marker id="arrow" ...><polygon .../></marker></defs>
  <!-- Nodes -->
  <rect x="..." y="..." rx="..." fill="..." stroke="..." />
  <text x="..." y="..." font-size="...">Label</text>
</svg>
```

### JSON Export

Direct `JSONEncoder().encode(graphDocument)` — already fully Codable.

## OakReader Integration

### New Files

| File | Purpose |
|------|---------|
| `Models/GraphMapModel.swift` | `GraphMapMeta` view model + `GraphMapRecord` GRDB record |
| `Services/GraphService.swift` | GRDB CRUD + filesystem I/O for graph JSON |
| `ViewModels/GraphViewModel.swift` | `@Observable` state manager, AI generation |
| `Views/RightPanel/GraphPanelView.swift` | Panel UI: graph list + canvas |
| `Views/RightPanel/GraphToolbar.swift` | Layout/export/type toolbar |
| `Services/AI/GraphPromptBuilder.swift` | LLM prompt construction |

### Modified Files

| File | Change |
|------|--------|
| `Utilities/PDFConstants.swift` | Add `case graphMap` to `RightPanelMode` and `Plugin` |
| `Views/RightPanel/RightPanelView.swift` | Add `case .graphMap:` branch |
| `ViewModels/DocumentViewModel.swift` | Add lazy `graph: GraphViewModel` property |
| `Services/CatalogDatabase.swift` | Add `graph_maps` table migration |
| `Package.swift` (root) | Add `OakGraph` dependency |

### Database Schema

```sql
-- Migration: v4-graph-maps
CREATE TABLE graph_maps (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT '',
    graph_type TEXT NOT NULL DEFAULT 'conceptMap',
    is_pinned INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX idx_graph_maps_item_id ON graph_maps(item_id);
```

### Storage Layout

```
~/OakReader/storage/{storageKey}/
├── notes/
│   └── {noteId}.md
├── sessions/
│   └── {sessionId}.json
└── graphs/                          ← NEW
    └── {graphId}.json               ← Full GraphDocument JSON
```

### Plugin Registration

```swift
// PDFConstants.swift
enum RightPanelMode {
    case aiChat, notes, metadata, translation
    case graphMap    // ← NEW
}

enum Plugin {
    case notes, translation
    case graphMap    // ← NEW
}
```

### ViewModel Lazy Init

```swift
// DocumentViewModel.swift
private var _graph: GraphViewModel?
var graph: GraphViewModel {
    if let vm = _graph { return vm }
    let vm = GraphViewModel(parent: self, database: database, storageKey: storageKey)
    _graph = vm
    return vm
}
```

## AI Generation

### Prompt Strategy

Uses `ProviderRouter` directly (single-shot, not ChatEngine — same as TranslationViewModel).

**System prompt** instructs the LLM to output a JSON `GraphDocument`:

```
You are a knowledge graph generator. Given document text, produce a concept map
(or mind map) as JSON matching this exact schema:

{
  "title": "...",
  "graphType": "conceptMap",
  "nodes": [
    { "id": "uuid", "label": "2-5 word concept", "style": { ... } }
  ],
  "edges": [
    { "id": "uuid", "sourceId": "...", "targetId": "...", "label": "relationship verb" }
  ]
}

Guidelines:
- 8-20 nodes for concept maps, 10-30 for mind maps
- Node labels: 2-5 words, noun phrases
- Edge labels: 1-3 words, verb phrases (concept maps only)
- Use varied colors for different concept clusters
- Mind maps: set parentId to create tree structure, root node has null parentId
```

**User prompt** includes truncated document text (max 32K chars).

### Generation Flow

```
User clicks "Generate" →
  GraphPromptBuilder builds system + user prompts →
  ProviderRouter.provider(for: config) →
  Stream LLM response (accumulate full JSON) →
  JSONDecoder.decode(GraphDocument.self) →
  LayoutEngine.layout(&document) →
  GraphService.save(document) →
  Display on canvas
```

### Error Handling

- JSON parsing failure → show error, offer "Retry"
- Malformed node/edge references → filter out invalid edges
- Empty response → show "No graph generated" message

## Design Decisions

### Why SwiftUI Canvas (not WKWebView)?

- Native rendering: no JavaScript bridge latency
- GPU-accelerated: Canvas uses Metal under the hood
- Simpler hit testing: we own the coordinate space
- Consistent with OakReader's existing Canvas usage (ZoomableChapterTimelineView)

### Why separate SPM package?

- Follows OakReaderAI pattern: standalone, testable, reusable
- Clear dependency boundary (OakGraph has zero dependencies)
- Can be built independently: `swift build` in Packages/OakGraph/

### Why store metadata in GRDB + content on disk?

- Same pattern as Notes: lightweight queries for list display
- Full graph JSON can be large (many nodes) — better on filesystem
- Atomic file writes via `Data.write(to:options:.atomic)`

### Why force-directed over grid-based (Heimer)?

- Heimer's grid approach requires pre-allocated grid cells
- Force-directed is more natural for concept maps with varying connectivity
- Tree layout (Reingold-Tilford) is better than grid for mind maps
- Both algorithms are well-documented and straightforward to implement

## Reference: Heimer Architecture

Key patterns borrowed from Heimer (Qt/C++ mind map application):

| Heimer Pattern | OakGraph Adaptation |
|---------------|---------------------|
| `QGraphicsScene` for rendering | SwiftUI `Canvas` |
| `Graph` with hash-map storage | `GraphDocument` with `[NodeModel]` arrays |
| `LayoutOptimizer` (simulated annealing) | `ForceDirectedLayout` (spring-electric) |
| `Node.hpp` with connection handles | `NodeRenderer` with boundary intersection |
| `.alz` XML archive format | `.json` Codable format |
| `EditorService` orchestrator | `GraphViewModel` @Observable |
| `QGraphicsView` mouse handling | SwiftUI gesture modifiers |

## Performance Considerations

- Canvas re-renders on any state change — keep `GraphDocument` changes minimal
- Force-directed layout runs on a background thread, updates positions atomically
- For graphs >100 nodes: consider spatial indexing for hit testing
- Node size computation: cache resolved text sizes

## Testing Strategy

1. **Unit tests**: Layout engine output positions, hit testing geometry
2. **Integration test**: Encode/decode GraphDocument round-trip
3. **Manual verification**: Hardcoded 5-node graph renders correctly
4. **AI test**: Generate from sample PDF text, verify valid JSON output
