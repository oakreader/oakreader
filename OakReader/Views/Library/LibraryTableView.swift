import SwiftUI
import UniformTypeIdentifiers

// Items table: white bg, 13px font, colored tag squares inline
struct LibraryTableView: View {
    let appState: AppState
    @Binding var selection: Set<UUID>

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        let items = store.filteredItems

        if items.isEmpty {
            emptyState
        } else {
            Table(of: LibraryItem.self, selection: $selection) {
                TableColumn("Title") { item in
                    HStack(spacing: 7) {
                        Image(systemName: item.primaryAttachment?.attachmentType.icon ?? "doc")
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .font(.system(size: 14))
                            .accessibilityLabel(item.primaryAttachment?.attachmentType.label ?? "Document")

                        Text(item.title)
                            .font(.system(size: 14))
                            .lineLimit(1)

                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(Color(hex: "FAA700"))
                                .font(.system(size: 11))
                                .accessibilityLabel("Favorite")
                        }
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

                TableColumn("Date Added") { item in
                    Text(item.dateAdded, style: .date)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.55))
                }
                .width(min: 80, ideal: 120)

            } rows: {
                ForEach(items, id: \.id) { item in
                    TableRow(item)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenuItems(for: ids)
            } primaryAction: { ids in
                openItems(ids)
            }
            .onDrop(of: [.pdf, .html], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            if store.selectedTagOptionId != nil {
                Image(systemName: "tag")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.primary.opacity(0.15))
                    .accessibilityHidden(true)

                Text("No Items with This Tag")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))

                Text("Assign this tag to items from their properties panel.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .multilineTextAlignment(.center)
            } else if store.selectedCollectionId == SystemCollectionID.inbox {
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.primary.opacity(0.15))
                    .accessibilityHidden(true)

                Text("Inbox is Empty")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))

                Text("Items saved from the Chrome extension will appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "books.vertical")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.primary.opacity(0.15))
                    .accessibilityHidden(true)

                Text("Your Library is Empty")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))

                Text("Drag PDF files here or click + to add them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .multilineTextAlignment(.center)

                Button("Add PDFs...") {
                    importPDFs()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for ids: Set<UUID>) -> some View {
        let selectedItems = store.filteredItems.filter { ids.contains($0.id) }

        if selectedItems.count == 1, let item = selectedItems.first {
            Button("Open") { openItem(item) }

            Divider()

            Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                store.toggleFavorite(item)
            }

            let rootCollections = store.rootCollections.sorted(by: { $0.sortOrder < $1.sortOrder })
            if !rootCollections.isEmpty {
                Menu("Add to Collection") {
                    ForEach(rootCollections) { collection in
                        collectionMenuItem(for: item, collection: collection)
                    }
                }
            }

            // Property assignments via context menu
            let selectProperties = store.properties.filter { $0.type == .multiSelect || $0.type == .singleSelect }
            if !selectProperties.isEmpty {
                ForEach(selectProperties) { property in
                    Menu(property.name) {
                        ForEach(property.options) { option in
                            let isAssigned = item.propertyValues.contains { $0.option?.id == option.id }
                            Button {
                                if isAssigned {
                                    store.removeItemSelectValue(item: item, property: property, option: option)
                                } else {
                                    store.setItemSelectValue(item: item, property: property, option: option)
                                }
                            } label: {
                                Label {
                                    Text(option.name)
                                } icon: {
                                    Image(systemName: isAssigned ? "checkmark.circle.fill" : "circle.fill")
                                        .foregroundStyle(Color(hex: option.colorHex))
                                }
                            }
                        }
                    }
                }
            }

            // Citation
            if item.referenceMetadata != nil {
                Menu("Copy Citation") {
                    ForEach(CitationStyle.allCases) { style in
                        Button(style.displayName) {
                            store.copyCitation(item, style: style)
                        }
                    }
                }
            }

            Divider()

            if let sourceURL = item.sourceURL {
                Button("View Online") {
                    NSWorkspace.shared.open(sourceURL)
                }
            }

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            }

            Divider()

            Button("Remove from Library", role: .destructive) {
                store.removeItem(item)
            }
        } else if selectedItems.count > 1 {
            Button("Open \(selectedItems.count) Items") {
                for item in selectedItems { openItem(item) }
            }

            // Export citations for multi-select
            let itemsWithRefs = selectedItems.filter { $0.referenceMetadata != nil }
            if !itemsWithRefs.isEmpty {
                Menu("Export Citations") {
                    Button("BibTeX") { exportCitations(itemsWithRefs, format: .bibtex) }
                    Button("RIS") { exportCitations(itemsWithRefs, format: .ris) }
                    Button("CSL JSON") { exportCitations(itemsWithRefs, format: .cslJson) }
                }
            }

            Divider()

            Button("Remove \(selectedItems.count) Items", role: .destructive) {
                for item in selectedItems { store.removeItem(item) }
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .html]
        panel.allowsMultipleSelection = true
        panel.message = "Select PDF or HTML files to add to your library"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                let ext = url.pathExtension.lowercased()
                let item: LibraryItem?
                if ext == "html" || ext == "htm" {
                    item = appState.importService.importWebSnapshot(from: url)
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
            // Try PDF first, then HTML
            let types = [UTType.pdf.identifier, UTType.html.identifier]
            for typeId in types {
                if provider.hasItemConformingToTypeIdentifier(typeId) {
                    provider.loadItem(forTypeIdentifier: typeId, options: nil) { data, _ in
                        guard let url = data as? URL else { return }
                        DispatchQueue.main.async {
                            let ext = url.pathExtension.lowercased()
                            let item: LibraryItem?
                            if ext == "html" || ext == "htm" {
                                item = appState.importService.importWebSnapshot(from: url)
                            } else {
                                item = appState.importService.importPDF(from: url)
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
}
