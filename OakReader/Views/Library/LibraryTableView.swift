import SwiftUI
import UniformTypeIdentifiers

// MARK: - Library Table Row

/// A row in the library table tree — either a parent item or one of its child attachments.
/// Used with `DisclosureTableRow` to provide Zotero-style expand/collapse for multi-attachment items.
struct LibraryRow: Identifiable {
    let id: UUID
    let parentItemId: UUID
    let kind: Kind

    enum Kind {
        case item(LibraryItem)
        case attachment(Attachment, parent: LibraryItem)
    }

    var isAttachment: Bool {
        if case .attachment = kind { return true }
        return false
    }

    /// The library item this row belongs to.
    var libraryItem: LibraryItem {
        switch kind {
        case .item(let item): return item
        case .attachment(_, let parent): return parent
        }
    }

    static func parent(_ item: LibraryItem) -> LibraryRow {
        LibraryRow(id: item.id, parentItemId: item.id, kind: .item(item))
    }

    static func child(_ attachment: Attachment, of item: LibraryItem) -> LibraryRow {
        LibraryRow(id: attachment.id, parentItemId: item.id, kind: .attachment(attachment, parent: item))
    }
}

// MARK: - Library Table View

// Items table: white bg, 13px font, colored tag squares inline
struct LibraryTableView: View {
    let appState: AppState
    @Binding var selection: Set<UUID>

    @State private var tableSelection: Set<UUID> = []
    @State private var transcriptionService = RecordingTranscriptionService()
    @State private var transcribingItemId: UUID?
    @State private var itemsPendingTrash: [LibraryItem] = []
    @State private var itemsPendingDelete: [LibraryItem] = []
    @State private var showEmptyBinConfirmation = false

    private var store: LibraryStore { appState.libraryStore }
    private var isBinMode: Bool { store.isBinSelected }

    private var isRecentlyRead: Bool {
        store.selectedCollectionId == SystemCollectionID.recentlyRead
    }

    private var dateColumnTitle: String {
        isRecentlyRead ? "Last Opened" : "Date Added"
    }

    private func dateColumnValue(for item: LibraryItem) -> Date {
        if isRecentlyRead, let lastOpened = item.lastOpenedAt {
            return lastOpened
        }
        return item.dateAdded
    }

    private var isDuplicatesMode: Bool {
        store.isDuplicatesSelected
    }

    var body: some View {
        let items = store.filteredItems
        let groupMap = isDuplicatesMode ? store.duplicateGroupIndexMap : [:]

        Table(of: LibraryRow.self, selection: $tableSelection) {
            TableColumn("Title") { row in
                HStack(spacing: 7) {
                    switch row.kind {
                    case .item(let item):
                        if isDuplicatesMode, let groupIdx = groupMap[item.id] {
                            Circle()
                                .fill(duplicateGroupColor(groupIdx))
                                .frame(width: 6, height: 6)
                        }

                        Image(systemName: item.displayIcon)
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .font(.system(size: 15))
                            .accessibilityLabel(item.primaryAttachment?.contentType.label ?? "Document")

                        if item.processingStatus == .transcribing || transcribingItemId == item.id {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else if item.processingStatus == .transcribed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 10))
                        } else if item.processingStatus == .failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 10))
                        }

                        Text(item.title)
                            .font(.system(size: 15))
                            .lineLimit(1)

                    case .attachment(let att, _):
                        Image(systemName: att.icon)
                            .foregroundStyle(Color.primary.opacity(0.3))
                            .font(.system(size: 13))
                            .accessibilityLabel(att.contentType.label)

                        Text(att.fileName)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 150, ideal: 300, max: .infinity)

            TableColumn("Author") { row in
                switch row.kind {
                case .item(let item):
                    Text(item.author)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .foregroundStyle(Color.primary.opacity(0.6))
                case .attachment(let att, _):
                    Text(att.contentType.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(Color.primary.opacity(0.4))
                }
            }
            .width(min: 80, ideal: 150, max: 280)

            TableColumn(dateColumnTitle) { row in
                switch row.kind {
                case .item(let item):
                    Text(dateColumnValue(for: item), style: .date)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.6))
                case .attachment(let att, _):
                    if att.fileSize > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: att.fileSize, countStyle: .file))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }
                }
            }
            .width(min: 80, ideal: 120, max: 200)

        } rows: {
            ForEach(items, id: \.id) { item in
                if item.attachments.count > 1 {
                    DisclosureTableRow(LibraryRow.parent(item)) {
                        ForEach(item.attachments.sorted { a, b in
                            if a.isPrimary != b.isPrimary { return a.isPrimary }
                            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
                        }) { attachment in
                            TableRow(LibraryRow.child(attachment, of: item))
                        }
                    }
                    .draggable(item.id.uuidString)
                } else {
                    TableRow(LibraryRow.parent(item))
                        .draggable(item.id.uuidString)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .background(TableHorizontalScrollerDisabler())
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenuItems(for: ids)
        } primaryAction: { ids in
            openRows(ids)
        }
        .onDrop(of: [.pdf, .html, .plainText, .audio, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .onHover { inside in
            if inside { NSCursor.arrow.set() }
        }
        .onChange(of: tableSelection) { _, newValue in
            let mapped = mapToItemIds(newValue)
            if mapped != selection { selection = mapped }
        }
        .onChange(of: selection) { _, newValue in
            if mapToItemIds(tableSelection) != newValue {
                tableSelection = newValue
            }
        }
        .onDeleteCommand {
            let items = store.filteredItems
            let allItemIds = mapToItemIds(tableSelection)
            let selectedItems = items.filter { allItemIds.contains($0.id) }
            guard !selectedItems.isEmpty else { return }
            if isBinMode {
                itemsPendingDelete = selectedItems
            } else {
                itemsPendingTrash = selectedItems
            }
        }
        .confirmationDialog(
            "Move to Bin?",
            isPresented: Binding(
                get: { !itemsPendingTrash.isEmpty },
                set: { if !$0 { itemsPendingTrash = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Bin", role: .destructive) {
                store.trashItems(itemsPendingTrash)
                itemsPendingTrash = []
            }
            Button("Cancel", role: .cancel) { itemsPendingTrash = [] }
        } message: {
            let count = itemsPendingTrash.count
            if count == 1 {
                Text("'\(itemsPendingTrash.first?.title ?? "")' will be moved to the Bin. You can restore it later.")
            } else {
                Text("\(count) items will be moved to the Bin. You can restore them later.")
            }
        }
        .confirmationDialog(
            "Delete Permanently?",
            isPresented: Binding(
                get: { !itemsPendingDelete.isEmpty },
                set: { if !$0 { itemsPendingDelete = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                for item in itemsPendingDelete { store.removeItem(item) }
                itemsPendingDelete = []
            }
            Button("Cancel", role: .cancel) { itemsPendingDelete = [] }
        } message: {
            let count = itemsPendingDelete.count
            if count == 1 {
                Text("'\(itemsPendingDelete.first?.title ?? "")' will be permanently deleted. This cannot be undone.")
            } else {
                Text("\(count) items will be permanently deleted. This cannot be undone.")
            }
        }
        .confirmationDialog(
            "Empty Bin?",
            isPresented: $showEmptyBinConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Bin", role: .destructive) {
                store.emptyBin()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All items in the Bin will be permanently deleted. This cannot be undone.")
        }
    }

    // MARK: - Selection Mapping

    /// Maps row IDs (item or attachment) back to parent item IDs.
    private func mapToItemIds(_ rowIds: Set<UUID>) -> Set<UUID> {
        let items = store.filteredItems
        var result = Set<UUID>()
        for rowId in rowIds {
            if items.contains(where: { $0.id == rowId }) {
                result.insert(rowId)
            } else {
                for item in items where item.attachments.contains(where: { $0.id == rowId }) {
                    result.insert(item.id)
                    break
                }
            }
        }
        return result
    }

    /// Resolves a row ID to the parent LibraryItem.
    private func resolveItem(for rowId: UUID) -> LibraryItem? {
        let items = store.filteredItems
        if let item = items.first(where: { $0.id == rowId }) { return item }
        return items.first { $0.attachments.contains { $0.id == rowId } }
    }

    /// Resolves a row ID to an Attachment and its parent item, if it's an attachment row.
    private func resolveAttachment(for rowId: UUID) -> (Attachment, LibraryItem)? {
        for item in store.filteredItems {
            if let att = item.attachments.first(where: { $0.id == rowId }) {
                return (att, item)
            }
        }
        return nil
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for ids: Set<UUID>) -> some View {
        let items = store.filteredItems
        let itemIds = ids.filter { id in items.contains { $0.id == id } }
        let attachmentIds = ids.subtracting(itemIds)

        if ids.isEmpty {
            emptySelectionMenu()
        } else if attachmentIds.count == 1, itemIds.isEmpty,
                  let attId = attachmentIds.first,
                  let (att, parentItem) = resolveAttachment(for: attId) {
            attachmentContextMenu(att, parent: parentItem)
        } else {
            // Resolve all IDs to items (attachment IDs map to their parent item)
            let allItemIds = mapToItemIds(ids)
            let selectedItems = items.filter { allItemIds.contains($0.id) }

            if selectedItems.count == 1, let item = selectedItems.first {
                singleItemContextMenu(item)
            } else if selectedItems.count > 1 {
                multiItemContextMenu(selectedItems)
            }
        }
    }

    @ViewBuilder
    private func attachmentContextMenu(_ att: Attachment, parent: LibraryItem) -> some View {
        Button { openItem(parent) } label: {
            Label("Open", systemImage: "doc.richtext")
        }

        Divider()

        if let sourceURL = att.sourceURL {
            Button { NSWorkspace.shared.open(sourceURL) } label: {
                Label("View Source in Browser", systemImage: "safari")
            }
        }

        Button { NSWorkspace.shared.activateFileViewerSelecting([att.fileURL]) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Button {
            let shareItem: Any = att.sourceURL ?? att.fileURL
            SharingService.share(items: [shareItem])
        } label: {
            Label("Share...", systemImage: "square.and.arrow.up")
        }
    }

    @ViewBuilder
    private func singleItemContextMenu(_ item: LibraryItem) -> some View {
        Button { openItem(item) } label: {
            Label("Open", systemImage: "doc.richtext")
        }

        Divider()

        let rootCollections = store.rootCollections.sorted(by: { $0.sortOrder < $1.sortOrder })
        if !rootCollections.isEmpty {
            Menu {
                ForEach(rootCollections) { collection in
                    collectionMenuItem(for: item, collection: collection)
                }
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
                    .accessibilityLabel(Text("Add to Collection"))
            }
        }

        if item.contentType == .audio {
            Button {
                transcribeAudioItem(item)
            } label: {
                Label("Transcribe", systemImage: "captions.bubble")
            }
            .disabled(
                !VoiceProviderFactory.isSTTConfigured
                || item.processingStatus == .transcribed
                || item.processingStatus == .transcribing
                || transcribingItemId != nil
            )
        }

        // Property assignments via context menu
        let selectProperties = store.properties.filter { $0.type == .multiSelect || $0.type == .singleSelect }
        if !selectProperties.isEmpty {
            ForEach(selectProperties) { property in
                Menu {
                    PropertyOptionAssignmentMenuItems(
                        item: item,
                        property: property,
                        store: store,
                        mode: .toggleAssigned
                    )
                } label: {
                    Label(property.name, systemImage: "tag")
                        .accessibilityLabel(Text(property.name))
                }
            }
        }

        // Citation
        if item.referenceMetadata != nil {
            Menu {
                ForEach(CitationStyle.allCases) { style in
                    Button(style.displayName) {
                        store.copyCitation(item, style: style)
                    }
                }
            } label: {
                Label("Copy Citation", systemImage: "quote.opening")
                    .accessibilityLabel(Text("Copy Citation"))
            }
        }

        Divider()

        if let sourceURL = item.sourceURL {
            Button { NSWorkspace.shared.open(sourceURL) } label: {
                Label("View Source in Browser", systemImage: "safari")
            }
        }

        Button { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Button {
            let shareItem: Any = item.sourceURL ?? item.fileURL
            SharingService.share(items: [shareItem])
        } label: {
            Label("Share...", systemImage: "square.and.arrow.up")
        }

        Divider()

        if isBinMode {
            Button { store.restoreItem(item) } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { itemsPendingDelete = [item] } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) { itemsPendingTrash = [item] } label: {
                Label("Move to Bin", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func multiItemContextMenu(_ selectedItems: [LibraryItem]) -> some View {
        Button { for item in selectedItems { openItem(item) } } label: {
            Label("Open \(selectedItems.count) Items", systemImage: "doc.richtext")
        }

        Divider()

        let rootCollections = store.rootCollections.sorted(by: { $0.sortOrder < $1.sortOrder })
        if !rootCollections.isEmpty {
            Menu {
                ForEach(rootCollections) { collection in
                    collectionMenuItem(for: selectedItems, collection: collection)
                }
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
                    .accessibilityLabel(Text("Add to Collection"))
            }
        }

        // Export citations for multi-select
        let itemsWithRefs = selectedItems.filter { $0.referenceMetadata != nil }
        if !itemsWithRefs.isEmpty {
            Menu {
                Button("BibTeX") { exportCitations(itemsWithRefs, format: .bibtex) }
                Button("RIS") { exportCitations(itemsWithRefs, format: .ris) }
                Button("CSL JSON") { exportCitations(itemsWithRefs, format: .cslJson) }
            } label: {
                Label("Export Citations", systemImage: "quote.opening")
                    .accessibilityLabel(Text("Export Citations"))
            }
        }

        let shareURLs: [Any] = selectedItems.compactMap { $0.sourceURL ?? $0.fileURL }
        if !shareURLs.isEmpty {
            Button {
                SharingService.share(items: shareURLs)
            } label: {
                Label("Share \(shareURLs.count) Links", systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        if isBinMode {
            Button { store.restoreItems(selectedItems) } label: {
                Label("Restore \(selectedItems.count) Items", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { itemsPendingDelete = selectedItems } label: {
                Label("Delete \(selectedItems.count) Items Permanently", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) { itemsPendingTrash = selectedItems } label: {
                Label("Move \(selectedItems.count) Items to Bin", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func emptySelectionMenu() -> some View {
        if isBinMode {
            Button(role: .destructive) { showEmptyBinConfirmation = true } label: {
                Label("Empty Bin", systemImage: "trash")
            }
            .disabled(store.trashedItems.isEmpty)
        } else {
            Button {
                importPDFs()
            } label: {
                Label("Import File...", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Collection Menu (hierarchical)

    private func collectionMenuItem(for item: LibraryItem, collection: PDFCollection) -> AnyView {
        let children = collection.subcollections.filter { !$0.isSmart }.sorted(by: { $0.sortOrder < $1.sortOrder })
        if children.isEmpty {
            return AnyView(
                Button {
                    store.addItem(item, to: collection)
                } label: {
                    Label(collection.name, systemImage: "folder.fill")
                        .accessibilityLabel(Text(collection.name))
                }
            )
        } else {
            return AnyView(
                Menu {
                    Button {
                        store.addItem(item, to: collection)
                    } label: {
                        Label(collection.name, systemImage: "folder.fill")
                            .accessibilityLabel(Text(collection.name))
                    }
                    Divider()
                    ForEach(children) { child in
                        collectionMenuItem(for: item, collection: child)
                    }
                } label: {
                    Label(collection.name, systemImage: "folder.fill")
                        .accessibilityLabel(Text(collection.name))
                }
            )
        }
    }

    private func collectionMenuItem(for items: [LibraryItem], collection: PDFCollection) -> AnyView {
        let children = collection.subcollections.filter { !$0.isSmart }.sorted(by: { $0.sortOrder < $1.sortOrder })
        if children.isEmpty {
            return AnyView(
                Button {
                    for item in items { store.addItem(item, to: collection) }
                } label: {
                    Label(collection.name, systemImage: "folder.fill")
                        .accessibilityLabel(Text(collection.name))
                }
            )
        } else {
            return AnyView(
                Menu {
                    Button {
                        for item in items { store.addItem(item, to: collection) }
                    } label: {
                        Label(collection.name, systemImage: "folder.fill")
                            .accessibilityLabel(Text(collection.name))
                    }
                    Divider()
                    ForEach(children) { child in
                        collectionMenuItem(for: items, collection: child)
                    }
                } label: {
                    Label(collection.name, systemImage: "folder.fill")
                        .accessibilityLabel(Text(collection.name))
                }
            )
        }
    }

    // MARK: - Actions

    private func openRows(_ ids: Set<UUID>) {
        for id in ids {
            if let item = resolveItem(for: id) {
                openItem(item)
            }
        }
    }

    private func openItem(_ item: LibraryItem) {
        appState.openLibraryItem(item)
    }

    private func transcribeAudioItem(_ item: LibraryItem) {
        guard let attachment = item.primaryAttachment else { return }
        guard VoiceProviderFactory.isSTTConfigured else { return }

        transcribingItemId = item.id
        store.updateProcessingStatus(item, status: .transcribing)
        Task {
            do {
                let text = try await transcriptionService.transcribe(
                    audioURL: attachment.fileURL
                )
                let url = CatalogDatabase.attachmentTranscriptURL(
                    itemStorageKey: attachment.itemStorageKey,
                    attachmentStorageKey: attachment.storageKey
                )
                try text.write(to: url, atomically: true, encoding: .utf8)
                store.updateProcessingStatus(item, status: .transcribed)
            } catch {
                Log.error(Log.audio, "Transcription failed: \(error)")
                store.updateProcessingStatus(item, status: .failed)
            }
            transcribingItemId = nil
        }
    }

    private func importPDFs() {
        var contentTypes: [UTType] = [.pdf, .html, .audio]
        if let mdType = UTType(filenameExtension: "md") {
            contentTypes.append(mdType)
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select files or folders to add to your library"
        panel.begin { response in
            guard response == .OK else { return }
            Task {
                for url in panel.urls {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        let count = await store.importFolder(url, importService: appState.importService)
                        await MainActor.run {
                            withAnimation {
                                appState.importNotification = "Imported \(count) item\(count == 1 ? "" : "s") from \"\(url.lastPathComponent)\""
                            }
                        }
                    } else {
                        let item = await appState.importService.importFileAsync(from: url)
                        if let item {
                            await MainActor.run {
                                if let collection = store.selectedCollection, !collection.isSmart {
                                    store.addItem(item, to: collection)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func exportCitations(_ items: [LibraryItem], format: CitationStyle) {
        let content: String
        let ext: String
        switch format {
        case .bibtex:
            content = store.exportBibTeX(items: items)
            ext = "bib"
        case .ris:
            content = store.exportRIS(items: items)
            ext = "ris"
        case .cslJson:
            content = store.exportCSLJSON(items: items)
            ext = "json"
        default:
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "references.\(ext)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            let types = [UTType.pdf.identifier, UTType.html.identifier, UTType.audio.identifier, UTType.fileURL.identifier]
            for typeId in types {
                if provider.hasItemConformingToTypeIdentifier(typeId) {
                    provider.loadItem(forTypeIdentifier: typeId, options: nil) { data, _ in
                        guard let url = data as? URL else { return }
                        // Check if it's a directory — import as collection
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            Task {
                                let count = await store.importFolder(url, importService: appState.importService)
                                await MainActor.run {
                                    withAnimation {
                                        appState.importNotification = "Imported \(count) item\(count == 1 ? "" : "s") from \"\(url.lastPathComponent)\""
                                    }
                                }
                            }
                            return
                        }
                        // Single file import
                        Task {
                            let item = await appState.importService.importFileAsync(from: url)
                            if let item {
                                await MainActor.run {
                                    if let collection = store.selectedCollection, !collection.isSmart {
                                        store.addItem(item, to: collection)
                                    }
                                }
                            }
                        }
                    }
                    break
                }
            }
        }
    }

    // MARK: - Duplicate Group Colors

    private static let groupColors: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .mint
    ]

    private func duplicateGroupColor(_ index: Int) -> Color {
        Self.groupColors[index % Self.groupColors.count].opacity(0.7)
    }
}
