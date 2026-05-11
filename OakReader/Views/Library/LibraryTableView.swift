import SwiftUI
import UniformTypeIdentifiers

// Items table: white bg, 13px font, colored tag squares inline
struct LibraryTableView: View {
    let appState: AppState
    @Binding var selection: Set<UUID>

    private var store: LibraryStore { appState.libraryStore }

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

    var body: some View {
        let items = store.filteredItems

        Table(of: LibraryItem.self, selection: $selection) {
            TableColumn("Title") { item in
                HStack(spacing: 7) {
                    Image(systemName: item.displayIcon)
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .font(.system(size: 14))
                        .accessibilityLabel(item.primaryAttachment?.attachmentType.label ?? "Document")

                    Text(item.title)
                        .font(.system(size: 14))
                        .lineLimit(1)

                }
            }
            .width(min: 150, ideal: 300)

            TableColumn("Author") { item in
                Text(item.author)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            .width(min: 80, ideal: 150)

            TableColumn(dateColumnTitle) { item in
                Text(dateColumnValue(for: item), style: .date)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            .width(min: 80, ideal: 120)

        } rows: {
            ForEach(items, id: \.id) { item in
                TableRow(item)
                    .draggable(item.id.uuidString)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenuItems(for: ids)
        } primaryAction: { ids in
            openItems(ids)
        }
        .onDrop(of: [.pdf, .html, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for ids: Set<UUID>) -> some View {
        let selectedItems = store.filteredItems.filter { ids.contains($0.id) }

        if selectedItems.count == 1, let item = selectedItems.first {
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
                }
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

            Divider()

            Button(role: .destructive) { store.removeItem(item) } label: {
                Label("Remove from Library", systemImage: "trash")
            }
        } else if selectedItems.isEmpty {
            Button {
                createNewNote()
            } label: {
                Label("Add Note", systemImage: "doc.text")
            }
            Button {
                importPDFs()
            } label: {
                Label("Import File...", systemImage: "doc.badge.plus")
            }
        } else if selectedItems.count > 1 {
            Button { for item in selectedItems { openItem(item) } } label: {
                Label("Open \(selectedItems.count) Items", systemImage: "doc.richtext")
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
                }
            }

            Divider()

            Button(role: .destructive) { for item in selectedItems { store.removeItem(item) } } label: {
                Label("Remove \(selectedItems.count) Items", systemImage: "trash")
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
                }
            )
        } else {
            return AnyView(
                Menu {
                    Button {
                        store.addItem(item, to: collection)
                    } label: {
                        Label(collection.name, systemImage: "folder.fill")
                    }
                    Divider()
                    ForEach(children) { child in
                        collectionMenuItem(for: item, collection: child)
                    }
                } label: {
                    Label(collection.name, systemImage: "folder.fill")
                }
            )
        }
    }

    // MARK: - Actions

    private func openItems(_ ids: Set<UUID>) {
        for id in ids {
            if let item = store.filteredItems.first(where: { $0.id == id }) {
                openItem(item)
            }
        }
    }

    private func openItem(_ item: LibraryItem) {
        appState.openLibraryItem(item)
    }

    private func importPDFs() {
        var contentTypes: [UTType] = [.pdf, .html]
        if let mdType = UTType(filenameExtension: "md") {
            contentTypes.append(mdType)
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Select PDF, HTML, or Markdown files to add to your library"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                let ext = url.pathExtension.lowercased()
                let item: LibraryItem?
                if ext == "html" || ext == "htm" {
                    item = appState.importService.importWebSnapshot(from: url)
                } else if ext == "md" || ext == "markdown" {
                    item = appState.importService.importMarkdown(from: url)
                } else {
                    item = appState.importService.importPDF(from: url)
                }
                if let item, let collection = store.selectedCollection, !collection.isSmart {
                    store.addItem(item, to: collection)
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
            // Try PDF first, then HTML, then plain text (for .md files)
            let types = [UTType.pdf.identifier, UTType.html.identifier, UTType.fileURL.identifier]
            for typeId in types {
                if provider.hasItemConformingToTypeIdentifier(typeId) {
                    provider.loadItem(forTypeIdentifier: typeId, options: nil) { data, _ in
                        guard let url = data as? URL else { return }
                        DispatchQueue.main.async {
                            let ext = url.pathExtension.lowercased()
                            let item: LibraryItem?
                            if ext == "html" || ext == "htm" {
                                item = appState.importService.importWebSnapshot(from: url)
                            } else if ext == "md" || ext == "markdown" {
                                item = appState.importService.importMarkdown(from: url)
                            } else if ext == "pdf" {
                                item = appState.importService.importPDF(from: url)
                            } else {
                                item = nil
                            }
                            if let item, let collection = store.selectedCollection, !collection.isSmart {
                                store.addItem(item, to: collection)
                            }
                        }
                    }
                    break
                }
            }
        }
    }

    private func createNewNote() {
        if let item = appState.importService.createStandaloneNote() {
            if let collection = store.selectedCollection, !collection.isSmart {
                store.addItem(item, to: collection)
            }
            appState.openLibraryItem(item)
        }
    }
}
