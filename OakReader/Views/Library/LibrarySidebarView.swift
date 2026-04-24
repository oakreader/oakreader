import SwiftUI

struct LibrarySidebarView: View {
    let appState: AppState

    @State private var showNewCollection = false
    @State private var newSubcollectionParent: PDFCollection?
    @State private var expandedCollections: Set<UUID> = []

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - My Library section
            sectionHeader("MY LIBRARY")

            filterRow(label: "All PDFs", icon: "books.vertical", filter: .all)
            filterRow(label: "Recently Added", icon: "clock", filter: .recentlyAdded)
            filterRow(label: "Favorites", icon: "star", filter: .favorites)

            Spacer().frame(height: 18)

            // MARK: - Collections section
            HStack {
                sectionHeader("COLLECTIONS")
                Spacer()
                Button {
                    importFolderAsCollection()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: OakStyle.Font.icon, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Import Folder as Collection")
                Button {
                    showNewCollection = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: OakStyle.Font.icon, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Collection")
                .padding(.trailing, 14)
            }
            .contextMenu {
                Button("New Collection") {
                    showNewCollection = true
                }
                Button("Import Folder as Collection...") {
                    importFolderAsCollection()
                }
            }

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(store.rootCollections.sorted(by: { $0.sortOrder < $1.sortOrder })) { collection in
                        CollectionRowView(
                            collection: collection,
                            depth: 0,
                            store: store,
                            appState: appState,
                            expandedCollections: $expandedCollections,
                            newSubcollectionParent: $newSubcollectionParent
                        )
                    }
                }
            }

            Spacer()

            // MARK: - Tags section
            Divider()
                .padding(.horizontal, 14)

            TagSelectorView(store: store)
        }
        .background(OakStyle.Colors.sidebarBackground)
        .sheet(isPresented: $showNewCollection) {
            CollectionEditorSheet(store: store, collection: nil)
        }
        .sheet(item: $newSubcollectionParent) { parent in
            SubcollectionEditorSheet(store: store, parent: parent)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Color(nsColor: .labelColor).opacity(0.55))
            .tracking(0.5)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
    }

    // MARK: - Import Folder

    private func importFolderAsCollection() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to import as a collection"
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let count = store.importFolder(url, importService: appState.importService)
        NSLog("[Library] Imported \(count) PDFs from folder: \(url.lastPathComponent)")
    }

    // MARK: - Filter Row

    private func filterRow(label: String, icon: String, filter: LibraryFilter) -> some View {
        let isSelected = store.selectedCollection == nil && store.currentFilter == filter && appState.isLibraryActive

        return Button {
            store.selectedCollection = nil
            store.currentFilter = filter
            appState.switchToLibrary()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: OakStyle.Font.icon))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .frame(width: 18)

                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .padding(.horizontal, 10)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Collection Row

private struct CollectionRowView: View {
    let collection: PDFCollection
    let depth: Int
    let store: LibraryStore
    let appState: AppState
    @Binding var expandedCollections: Set<UUID>
    @Binding var newSubcollectionParent: PDFCollection?

    private var isSelected: Bool {
        store.selectedCollection?.id == collection.id && appState.isLibraryActive
    }

    private var hasChildren: Bool {
        !collection.subcollections.isEmpty
    }

    private var isExpanded: Bool {
        expandedCollections.contains(collection.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                store.selectedCollection = collection
                store.currentFilter = .all
                appState.switchToLibrary()
            } label: {
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: CGFloat(depth) * 16)

                    // Disclosure triangle
                    if hasChildren {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isExpanded {
                                    expandedCollections.remove(collection.id)
                                } else {
                                    expandedCollections.insert(collection.id)
                                }
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer().frame(width: 16)
                    }

                    Image(systemName: collection.icon)
                        .font(.system(size: OakStyle.Font.icon))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .frame(width: 18)
                        .padding(.trailing, 6)

                    Text(collection.name)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Spacer()

                    let count = collection.itemCount
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                            .padding(.trailing, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .padding(.horizontal, 10)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename...") {
                    renameCollection(collection)
                }
                Button("New Subcollection") {
                    newSubcollectionParent = collection
                }
                Divider()
                if collection.parentId != nil {
                    Button("Move to Root") {
                        store.moveCollection(collection, toParent: nil)
                    }
                }
                Menu("Move to...") {
                    ForEach(store.rootCollections.filter { $0.id != collection.id }) { target in
                        Button(target.name) {
                            store.moveCollection(collection, toParent: target)
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    store.deleteCollection(collection)
                }
            }

            // Subcollections (recursive)
            if hasChildren && isExpanded {
                ForEach(collection.subcollections.sorted(by: { $0.sortOrder < $1.sortOrder })) { child in
                    CollectionRowView(
                        collection: child,
                        depth: depth + 1,
                        store: store,
                        appState: appState,
                        expandedCollections: $expandedCollections,
                        newSubcollectionParent: $newSubcollectionParent
                    )
                }
            }
        }
    }

    private func renameCollection(_ collection: PDFCollection) {
        let alert = NSAlert()
        alert.messageText = "Rename Collection"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = collection.name
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                store.renameCollection(collection, to: name)
            }
        }
    }
}

// MARK: - Subcollection Editor Sheet

private struct SubcollectionEditorSheet: View {
    let store: LibraryStore
    let parent: PDFCollection

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var icon: String = "folder"

    private let iconOptions = [
        "folder", "folder.fill", "tray.full", "books.vertical",
        "star", "bookmark", "tag", "archivebox",
        "graduationcap", "briefcase", "heart", "flag"
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("New Subcollection")
                .font(.headline)

            Text("Under: \(parent.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Subcollection Name", text: $name)
                .textFieldStyle(.roundedBorder)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 8) {
                ForEach(iconOptions, id: \.self) { iconName in
                    Button {
                        icon = iconName
                    } label: {
                        Image(systemName: iconName)
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(icon == iconName ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(icon == iconName ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    store.createSubcollection(name: trimmed, icon: icon, parent: parent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
    }
}
