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
            Table(of: PDFLibraryItem.self, selection: $selection) {
                TableColumn("Title") { item in
                    HStack(spacing: 7) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .font(.system(size: 14))

                        // Tag swatches: overlapping colored squares
                        if !item.tags.isEmpty {
                            HStack(spacing: -3) {
                                ForEach(item.tags.prefix(3), id: \.id) { tag in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: tag.colorHex))
                                        .frame(width: 11, height: 11)
                                }
                            }
                            .padding(.trailing, 2)
                        }

                        Text(item.title)
                            .font(.system(size: 14))
                            .lineLimit(1)

                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(Color(hex: "FAA700"))
                                .font(.system(size: 11))
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

                TableColumn("Pages") { item in
                    Text("\(item.pageCount)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .monospacedDigit()
                }
                .width(min: 50, ideal: 60)

                TableColumn("Size") { item in
                    Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.55))
                }
                .width(min: 60, ideal: 80)
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
            .onDrop(of: [.pdf], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(Color.primary.opacity(0.15))

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

            if !store.collections.isEmpty {
                Menu("Add to Collection") {
                    ForEach(store.collections) { collection in
                        Button(collection.name) {
                            store.addItem(item, to: collection)
                        }
                    }
                }
            }

            if !store.tags.isEmpty {
                Menu("Add Tag") {
                    ForEach(store.tags, id: \.id) { tag in
                        Button {
                            store.addTag(tag, to: item)
                        } label: {
                            Label(tag.name, systemImage: item.tags.contains(where: { $0.id == tag.id }) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }

            Divider()

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

            Divider()

            Button("Remove \(selectedItems.count) Items", role: .destructive) {
                for item in selectedItems { store.removeItem(item) }
            }
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

    private func openItem(_ item: PDFLibraryItem) {
        appState.openLibraryItem(item)
    }

    private func importPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Select PDF files to add to your library"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let item = appState.importService.importPDF(from: url) {
                    if let collection = store.selectedCollection {
                        store.addItem(item, to: collection)
                    }
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.pdf.identifier, options: nil) { data, _ in
                guard let url = data as? URL else { return }
                DispatchQueue.main.async {
                    if let item = appState.importService.importPDF(from: url) {
                        if let collection = store.selectedCollection {
                            store.addItem(item, to: collection)
                        }
                    }
                }
            }
        }
    }
}
