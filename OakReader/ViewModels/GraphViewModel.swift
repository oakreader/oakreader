import Foundation
import OakGraph
import OakReaderAI

@Observable
class GraphViewModel {
    weak var parent: DocumentViewModel?

    // MARK: - State

    var graphs: [GraphMapMeta] = []
    var selectedGraphId: UUID?
    var currentDocument: GraphDocument?
    var interaction = GraphInteractionState()
    var isGenerating: Bool = false
    var errorMessage: String?

    var selectedGraph: GraphMapMeta? {
        guard let id = selectedGraphId else { return nil }
        return graphs.first { $0.id == id }
    }

    // MARK: - Private

    private let graphService = GraphService()
    private let storageKey: String?
    private var generateTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    // MARK: - Init

    init(parent: DocumentViewModel? = nil, storageKey: String?) {
        self.parent = parent
        self.storageKey = storageKey
        loadGraphs()
    }

    // MARK: - Load

    func loadGraphs() {
        guard let storageKey else {
            graphs = []
            return
        }
        graphs = graphService.fetchGraphs(storageKey: storageKey)
    }

    // MARK: - Select

    func selectGraph(_ graph: GraphMapMeta) {
        selectedGraphId = graph.id
        interaction = GraphInteractionState()

        if let storageKey {
            currentDocument = graphService.loadDocument(graphId: graph.id, storageKey: storageKey)
        } else {
            currentDocument = nil
        }
    }

    func deselectGraph() {
        saveCurrentGraphIfNeeded()
        selectedGraphId = nil
        currentDocument = nil
        interaction = GraphInteractionState()
    }

    // MARK: - Node Manipulation

    func moveNode(_ nodeId: UUID, to position: CGPoint) {
        guard var doc = currentDocument,
              let idx = doc.nodeIndex(withId: nodeId) else { return }
        doc.nodes[idx].position = position
        currentDocument = doc
        scheduleSave()
    }

    func updateNodeLabel(_ nodeId: UUID, label: String) {
        guard var doc = currentDocument,
              let idx = doc.nodeIndex(withId: nodeId) else { return }
        doc.nodes[idx].label = label
        doc.nodes[idx].autoSize()
        currentDocument = doc
        scheduleSave()
    }

    func deleteSelected() {
        guard var doc = currentDocument else { return }

        if let nodeId = interaction.selectedNodeId {
            doc.removeNode(nodeId)
            interaction.clearSelection()
        } else if let edgeId = interaction.selectedEdgeId {
            doc.removeEdge(edgeId)
            interaction.clearSelection()
        }

        currentDocument = doc
        scheduleSave()
    }

    // MARK: - Layout

    func relayout() {
        guard var doc = currentDocument else { return }
        let engine: LayoutEngine = doc.graphType == .mindMap ? TreeLayout() : ForceDirectedLayout()
        engine.layout(&doc)
        currentDocument = doc
        scheduleSave()
    }

    func switchGraphType(_ type: GraphType) {
        guard var doc = currentDocument else { return }
        doc.graphType = type
        let engine: LayoutEngine = type == .mindMap ? TreeLayout() : ForceDirectedLayout()
        engine.layout(&doc)
        currentDocument = doc
        scheduleSave()
    }

    // MARK: - AI Generation

    func generate(graphType: GraphType = .conceptMap) {
        guard let parent, let storageKey else { return }

        stopGeneration()
        isGenerating = true
        errorMessage = nil

        let contextProvider = PDFContextProvider()
        guard let snapshot = contextProvider.snapshot(from: parent, contextMode: .fullDocument) else {
            errorMessage = "Could not extract document text."
            isGenerating = false
            return
        }

        let documentText = snapshot.fullDocumentText ?? snapshot.currentPageText
        let systemPrompt = GraphPromptBuilder.systemPrompt(graphType: graphType)
        let userPrompt = GraphPromptBuilder.userPrompt(documentText: documentText, graphType: graphType)

        let prefs = Preferences.shared
        let pid = prefs.translationAIProviderId
        let model: String = {
            let m = prefs.translationAIModel
            return m.isEmpty ? (ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? "") : m
        }()

        let config = ProviderConfig(providerId: pid, model: model)
        let messages = [LLMMessage(role: .user, text: userPrompt)]
        let router = ProviderRouter()
        let svc = graphService

        generateTask = Task { @MainActor in
            var accumulated = ""
            do {
                let provider = try router.provider(for: config)
                let stream = provider.sendMessage(
                    messages: messages,
                    model: model,
                    systemPrompt: systemPrompt,
                    maxTokens: 8192
                )

                for try await chunk in stream {
                    switch chunk {
                    case .delta(let delta):
                        accumulated += delta
                    case .toolUse:
                        break
                    case .finished:
                        break
                    case .error(let msg):
                        errorMessage = msg
                    }
                }

                // Parse the JSON response
                let jsonString = Self.extractJSON(from: accumulated)
                guard let jsonData = jsonString.data(using: .utf8) else {
                    errorMessage = "Empty response from AI."
                    isGenerating = false
                    return
                }

                var document = try JSONDecoder().decode(GraphDocument.self, from: jsonData)
                document.sanitizeEdges()
                document.autoSizeAllNodes()

                // Run layout
                let engine: LayoutEngine = document.graphType == .mindMap ? TreeLayout() : ForceDirectedLayout()
                engine.layout(&document)

                // Save to disk
                try svc.saveDocument(document, storageKey: storageKey)

                // Update UI
                let meta = GraphMapMeta(document: document)
                graphs.insert(meta, at: 0)
                selectGraph(meta)
                currentDocument = document

            } catch is CancellationError {
                // User cancelled
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    func stopGeneration() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
    }

    // MARK: - Delete Graph

    func deleteGraph(_ graph: GraphMapMeta) {
        guard let storageKey else { return }
        graphService.deleteGraph(id: graph.id, storageKey: storageKey)
        graphs.removeAll { $0.id == graph.id }
        if selectedGraphId == graph.id {
            selectedGraphId = nil
            currentDocument = nil
        }
    }

    // MARK: - Export

    @MainActor
    func exportPNG() -> Data? {
        guard let doc = currentDocument else { return nil }
        return GraphExporter().exportPNG(doc)
    }

    func exportJSON() -> Data? {
        guard let doc = currentDocument else { return nil }
        return try? GraphExporter().exportJSON(doc)
    }

    func exportSVG() -> String? {
        guard let doc = currentDocument else { return nil }
        return GraphExporter().exportSVG(doc)
    }

    // MARK: - Auto-Save (debounced)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveCurrentGraphIfNeeded()
        }
    }

    private func saveCurrentGraphIfNeeded() {
        guard let document = currentDocument,
              let storageKey else { return }
        do {
            try graphService.saveDocument(document, storageKey: storageKey)
            if let idx = graphs.firstIndex(where: { $0.id == document.id }) {
                graphs[idx].title = document.title
                graphs[idx].updatedAt = Date()
            }
        } catch {
            Log.error(Log.store, "Failed to save graph: \(error)")
        }
    }

    // MARK: - JSON Extraction

    /// Extract JSON from LLM response, stripping markdown fences if present.
    private static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json ... ``` wrapper
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: "\n")
            let stripped = lines.dropFirst().dropLast().joined(separator: "\n")
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
