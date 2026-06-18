import SwiftUI
import GRDB

struct LibrarySettingsView: View {
    let store: LibraryStore

    @State private var indexedCount = 0
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var chunkCount = 0
    @State private var isRebuilding = false
    @State private var pollTask: Task<Void, Never>?

    private let systemCollections: [(id: UUID, name: String, icon: String)] = [
        (SystemCollectionID.allItems, "All Items", "books.vertical"),
        (SystemCollectionID.recentlyRead, "Recently Read", "book"),
        (SystemCollectionID.pdfs, "PDFs", "doc.fill"),
        (SystemCollectionID.html, "Web", "globe"),
    ]

    /// Real work only: items we haven't attempted yet. Skipped (empty) items are
    /// already processed, so this goes to zero when the background pass finishes.
    private var isIndexing: Bool { processedCount < totalCount }

    /// Processed but produced no chunks (image-only PDFs, links/HTML with no text).
    private var skippedCount: Int { max(0, processedCount - indexedCount) }

    var body: some View {
        Form {
            Section("Sidebar Collections") {
                Text("Choose which system collections appear in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(systemCollections, id: \.id) { item in
                    Toggle(isOn: Binding(
                        get: { !store.hiddenSystemCollectionIds.contains(item.id) },
                        set: { visible in
                            if visible {
                                store.hiddenSystemCollectionIds.remove(item.id)
                            } else {
                                store.hiddenSystemCollectionIds.insert(item.id)
                            }
                        }
                    )) {
                        Label(item.name, systemImage: item.icon)
                    }
                }
            }

            Section("Search Index") {
                LabeledContent("Indexed Items") {
                    Text("\(indexedCount) / \(totalCount)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                LabeledContent("Chunks") {
                    Text("\(chunkCount)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                if totalCount > 0 {
                    ProgressView(value: Double(processedCount), total: Double(totalCount))
                        .animation(.default, value: processedCount)
                }

                if isIndexing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        let remaining = totalCount - processedCount
                        Text("Indexing... \(remaining) item(s) remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if skippedCount > 0 {
                    Text("\(skippedCount) item(s) skipped — no extractable text (e.g. scanned PDFs)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    rebuildIndex()
                } label: {
                    Text("Rebuild Index")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRebuilding)

                Text("Clears the full-text search index and re-indexes all documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Private

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await loadStats()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @MainActor
    private func loadStats() async {
        let stats = try? FTSDatabase().indexStats()
        let total: Int = (try? await store.database.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM items i
                JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                WHERE a.content_type IN ('pdf', 'html', 'markdown', 'link')
                """)
        }) ?? 0

        withAnimation {
            indexedCount = stats?.indexedItemCount ?? 0
            processedCount = stats?.processedItemCount ?? 0
            chunkCount = stats?.totalChunkCount ?? 0
            totalCount = total
        }
    }

    private func rebuildIndex() {
        isRebuilding = true
        Task {
            do {
                try FTSDatabase().destroyAll()
            } catch {
                Log.error(Log.fts, "Failed to clear search index: \(error)")
            }

            await MainActor.run {
                withAnimation {
                    indexedCount = 0
                    processedCount = 0
                    chunkCount = 0
                }
            }

            NotificationCenter.default.post(name: .searchIndexRebuildRequested, object: nil)

            await MainActor.run {
                isRebuilding = false
            }
        }
    }
}
