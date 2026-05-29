import SwiftUI

struct LibrarySidebarView: View {
    let appState: AppState

    @State private var sidebarMode: LibrarySidebarMode = .collections
    @State private var showNewCollection = false
    @State private var showNewSmartCollection = false
    @State private var showNewTag = false
    @State private var newSubcollectionParent: PDFCollection?
    @State private var expandedCollections: Set<UUID> = []
    @State private var expandedTagNodes: Set<UUID> = []
    @State private var editingSmartCollection: PDFCollection?
    @State private var extensionRevision = 0
    @State private var showEmptyBinConfirmation = false

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            myLibrarySection

            Spacer().frame(height: 14)

            sectionSwitcher

            switch sidebarMode {
            case .collections:
                collectionsScrollView
            case .tags:
                tagsScrollView
            }

            Spacer()
        }
        .background(OakStyle.Colors.sidebarBackground)
        .sheet(isPresented: $showNewCollection) {
            CollectionEditorSheet(store: store, collection: nil, parent: nil)
        }
        .sheet(isPresented: $showNewSmartCollection) {
            SmartCollectionEditorSheet(store: store, collection: nil)
        }
        .sheet(item: $editingSmartCollection) { collection in
            SmartCollectionEditorSheet(store: store, collection: collection)
        }
        .sheet(item: $newSubcollectionParent) { parent in
            CollectionEditorSheet(store: store, collection: nil, parent: parent)
        }
        .sheet(isPresented: $showNewTag) {
            TagEditorSheet(store: store)
        }
        .onReceive(NotificationCenter.default.publisher(for: Preferences.appExtensionToggleNotification)) { _ in
            extensionRevision += 1
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

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Color(nsColor: .labelColor).opacity(0.55))
            .tracking(0.5)
            .padding(.horizontal, 20)
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
        Task {
            let count = await store.importFolder(url, importService: appState.importService)
            Log.info(Log.ui, "Imported \(count) items from folder: \(url.lastPathComponent)")
        }
    }

    // MARK: - Smart Collection Row

    private func smartCollectionRow(_ collection: PDFCollection) -> some View {
        let isSelected = store.selectedCollectionId == collection.id && store.selectedTagOptionId == nil && appState.isLibraryActive

        return Button {
            store.selectCollection(collection.id)
            appState.selectedLibraryItemIDs = []
            appState.switchToLibrary()
        } label: {
            HStack(spacing: 6) {
                Group {
                    if collection.icon.hasPrefix("icon-") {
                        Image(collection.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: collection.icon)
                            .font(.system(size: 14))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)

                Text(collection.name)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 12)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collection.name)
        .contextMenu {
            if collection.id == SystemCollectionID.duplicates {
                let groupCount = store.duplicateGroups.count
                Button {
                    mergeAllDuplicates()
                } label: {
                    Label("Merge All Duplicates", systemImage: "arrow.triangle.merge")
                }
                .disabled(groupCount == 0)
            }
            if collection.id == SystemCollectionID.bin {
                Button(role: .destructive) {
                    showEmptyBinConfirmation = true
                } label: {
                    Label("Empty Bin", systemImage: "trash")
                }
                .disabled(store.trashedItems.isEmpty)
            }
        }
    }

    private func mergeAllDuplicates() {
        let groups = store.duplicateGroups
        for group in groups {
            let sorted = group.sorted { $0.dateAdded < $1.dateAdded }
            guard let keeper = sorted.first else { continue }
            let others = Array(sorted.dropFirst())
            store.mergeItems(keeper: keeper, duplicates: others)
        }
    }

}

// MARK: - Subviews

private extension LibrarySidebarView {
    var myLibrarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("MY LIBRARY")

            ForEach(store.systemSmartCollections.sorted(by: { $0.sortOrder < $1.sortOrder })) { collection in
                if !store.hiddenSystemCollectionIds.contains(collection.id)
                    && !isCollectionDisabledByExtension(collection.id)
                    && collection.id != SystemCollectionID.quizCards {
                    smartCollectionRow(collection)
                }
            }
        }
    }

    func isCollectionDisabledByExtension(_ collectionId: UUID) -> Bool {
        _ = extensionRevision // force re-evaluation when extensions are toggled
        return AppExtension.allCases.contains { ext in
            ext.systemCollectionId == collectionId && !Preferences.shared.isExtensionEnabled(ext)
        }
    }

    var sectionSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(LibrarySidebarMode.allCases) { mode in
                let selected = sidebarMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sidebarMode = mode
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 11))
                        Text(mode.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color(nsColor: .textBackgroundColor) : .clear)
                            .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    /// Collect IDs of all nodes that have children.
    private func collectParentIds(from nodes: [TagNode]) -> Set<UUID> {
        var ids = Set<UUID>()
        for node in nodes {
            if !node.children.isEmpty {
                ids.insert(node.id)
                ids.formUnion(collectParentIds(from: node.children))
            }
        }
        return ids
    }

    var tagsScrollView: some View {
        ScrollView {
            let pairs = store.tagOptionsWithCounts()
            let nodes = TagNode.buildHierarchy(from: pairs)

            if nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.primary.opacity(0.15))
                    Text("No Tags")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Right-click to create a tag")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.25))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            } else {
                VStack(spacing: 1) {
                    ForEach(nodes) { node in
                        TagNodeRowView(
                            node: node,
                            depth: 0,
                            store: store,
                            appState: appState,
                            expandedTagNodes: $expandedTagNodes
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
                    let parentIds = collectParentIds(from: nodes)
                    expandedTagNodes.formUnion(parentIds)
                }
            }
        }
        .id(store.revision)
        .contextMenu {
            Button("New Tag...") {
                showNewTag = true
            }
            Divider()
            Button("Show Collections") {
                sidebarMode = .collections
            }
        }
    }

    var collectionsScrollView: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(store.rootCollections.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { collection in
                    CollectionRowView(
                        collection: collection,
                        depth: 0,
                        store: store,
                        appState: appState,
                        expandedCollections: $expandedCollections,
                        newSubcollectionParent: $newSubcollectionParent,
                        editingSmartCollection: $editingSmartCollection
                    )
                }
            }
            .id(store.revision)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            Button("New Collection") {
                showNewCollection = true
            }
            Button("New Smart Collection") {
                showNewSmartCollection = true
            }
            Divider()
            Button("Import Folder as Collection...") {
                importFolderAsCollection()
            }
        }
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
    @Binding var editingSmartCollection: PDFCollection?

    @State private var isDropTargeted = false
    @State private var showingDeleteConfirmation = false
    @State private var dragExpandTask: Task<Void, Never>?
    @State private var dropPulse = false

    private var isSelected: Bool {
        store.selectedCollectionId == collection.id && store.selectedTagOptionId == nil && appState.isLibraryActive
    }

    private var hasChildren: Bool {
        !collection.subcollections.isEmpty
    }

    private var isExpanded: Bool {
        expandedCollections.contains(collection.id)
    }

    /// Whether the drop highlight should be shown (targeted + a valid, non-smart destination).
    private var isDropActive: Bool {
        isDropTargeted && !collection.isSmart
    }

    /// Adds items (referenced by their UUID strings, dragged from the library table) to this collection.
    private func handleItemDrop(_ idStrings: [String]) -> Bool {
        guard !collection.isSmart else { return false }
        var added = false
        for idString in idStrings {
            guard let uuid = UUID(uuidString: idString),
                  let item = store.findItem(byId: uuid) else { continue }
            store.addItem(item, to: collection)
            added = true
        }
        if added { triggerDropPulse() }
        return added
    }

    /// Briefly flashes the collection row to confirm a successful drop.
    private func triggerDropPulse() {
        withAnimation(.easeOut(duration: 0.12)) { dropPulse = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeInOut(duration: 0.5)) { dropPulse = false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: CGFloat(depth) * 18)

                Image(systemName: collection.icon == "folder" ? "folder.fill" : collection.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 18)
                    .padding(.trailing, 5)

                Text(collection.name)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if hasChildren {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isExpanded {
                                    expandedCollections.remove(collection.id)
                                } else {
                                    expandedCollections.insert(collection.id)
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
            .background(
                Group {
                    if isDropActive {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.06))
                            )
                    } else if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .padding(.horizontal, 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isDropActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                    .padding(.horizontal, 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(dropPulse ? 0.22 : 0))
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            )
            .animation(.easeInOut(duration: 0.12), value: isDropActive)
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectCollection(collection.id)
                appState.selectedLibraryItemIDs = []
                appState.switchToLibrary()
            }
            .dropDestination(for: String.self) { droppedIDs, _ in
                handleItemDrop(droppedIDs)
            } isTargeted: { targeted in
                isDropTargeted = targeted && !collection.isSmart
            }
            .onChange(of: isDropTargeted) { _, targeted in
                dragExpandTask?.cancel()
                if targeted && !collection.isSmart && hasChildren && !isExpanded {
                    let collectionId = collection.id
                    dragExpandTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedCollections.insert(collectionId)
                        }
                    }
                }
            }
            .contextMenu {
                if collection.isSmart && !collection.isSystem {
                    Button { editingSmartCollection = collection } label: {
                        Label("Edit Smart Collection...", systemImage: "slider.horizontal.3")
                    }
                }
                if !collection.isSystem {
                    Button { renameCollection(collection) } label: {
                        Label("Rename...", systemImage: "pencil")
                    }
                }
                if !collection.isSmart {
                    Button { newSubcollectionParent = collection } label: {
                        Label("New Subcollection", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    if collection.parentId != nil {
                        Button { store.moveCollection(collection, toParent: nil) } label: {
                            Label("Move to Root", systemImage: "arrow.up.to.line")
                        }
                    }
                    Menu {
                        ForEach(store.rootCollections.filter { $0.id != collection.id }) { target in
                            Button(target.name) {
                                store.moveCollection(collection, toParent: target)
                            }
                        }
                    } label: {
                        Label("Move to...", systemImage: "folder.badge.gearshape")
                    }
                }
                // Remove duplicates within this collection
                if !collection.isSmart {
                    Divider()
                    Button {
                        let collectionItems = store.items.filter { $0.collections.contains { $0.id == collection.id } }
                        let collectionDuplicates = DuplicateService.findDuplicates(in: collectionItems)
                        for group in collectionDuplicates {
                            let sorted = group.sorted { $0.dateAdded < $1.dateAdded }
                            guard let keeper = sorted.first else { continue }
                            let others = Array(sorted.dropFirst())
                            store.mergeItems(keeper: keeper, duplicates: others)
                        }
                    } label: {
                        Label("Remove Duplicates", systemImage: "arrow.triangle.merge")
                    }
                }

                if appState.ftsIndexService != nil {
                    Divider()
                    Button {
                        embedCollectionContent(collection)
                    } label: {
                        Label("Index All Content", systemImage: "text.magnifyingglass")
                    }
                }

                if !collection.isSystem {
                    Divider()
                    Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            .confirmationDialog(
                "Delete \"\(collection.name)\"?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Collection and Quiz Cards", role: .destructive) {
                    store.deleteCollection(collection)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete this collection and all associated quiz cards. This action cannot be undone.")
            }

            // Subcollections (recursive)
            if hasChildren && isExpanded {
                ForEach(collection.subcollections.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { child in
                    CollectionRowView(
                        collection: child,
                        depth: depth + 1,
                        store: store,
                        appState: appState,
                        expandedCollections: $expandedCollections,
                        newSubcollectionParent: $newSubcollectionParent,
                        editingSmartCollection: $editingSmartCollection
                    )
                }
            }
        }
    }

    private func embedCollectionContent(_ collection: PDFCollection) {
        guard let service = appState.ftsIndexService else { return }
        let collectionItems = store.items.filter { $0.collections.contains { $0.id == collection.id } }
        let itemIds = collectionItems.map(\.id.uuidString)
        guard !itemIds.isEmpty else { return }
        Task {
            await service.indexItems(itemIds)
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

// MARK: - Tag Node Row

private struct TagNodeRowView: View {
    let node: TagNode
    let depth: Int
    let store: LibraryStore
    let appState: AppState
    @Binding var expandedTagNodes: Set<UUID>

    private var isSelected: Bool {
        store.selectedTagOptionId == node.option?.id && node.option != nil && appState.isLibraryActive
    }

    private var hasChildren: Bool {
        !node.children.isEmpty
    }

    private var isExpanded: Bool {
        expandedTagNodes.contains(node.id)
    }

    /// Color for this node: use the option's color, or derive from first child.
    private var nodeColorHex: String {
        if let option = node.option {
            return option.colorHex
        }
        return firstChildColorHex(in: node) ?? "90A4AE"
    }

    private func firstChildColorHex(in node: TagNode) -> String? {
        for child in node.children {
            if let option = child.option {
                return option.colorHex
            }
            if let found = firstChildColorHex(in: child) {
                return found
            }
        }
        return nil
    }

    private func toggleExpand() {
        withAnimation(.easeInOut(duration: 0.15)) {
            if isExpanded {
                expandedTagNodes.remove(node.id)
            } else {
                expandedTagNodes.insert(node.id)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if let option = node.option {
                    store.selectTag(option.id)
                    appState.selectedLibraryItemIDs = []
                    appState.switchToLibrary()
                } else if hasChildren {
                    toggleExpand()
                }
            } label: {
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: CGFloat(depth) * 16)

                    // Color indicator
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: nodeColorHex))
                        .frame(width: 11, height: 11)
                        .padding(.trailing, 5)

                    Text(node.name)
                        .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    let total = node.totalCount()
                    if total > 0 {
                        Text("\(total)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }

                    if hasChildren {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                            .onTapGesture { toggleExpand() }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                        .padding(.horizontal, 12)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let option = node.option {
                    Button { renameTag(option) } label: {
                        Label("Rename...", systemImage: "pencil")
                    }
                    Menu {
                        ForEach(tagColorPalette, id: \.hex) { entry in
                            Button {
                                store.updatePropertyOptionColor(option, colorHex: entry.hex)
                            } label: {
                                Label(entry.name, systemImage: option.colorHex == entry.hex ? "checkmark.circle.fill" : "circle.fill")
                            }
                            .tint(Color(hex: entry.hex))
                        }
                    } label: {
                        Label("Change Color", systemImage: "paintpalette")
                    }
                    Divider()
                    Button(role: .destructive) { store.removePropertyOption(option) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            // Children (recursive)
            if hasChildren && isExpanded {
                ForEach(node.children) { child in
                    TagNodeRowView(
                        node: child,
                        depth: depth + 1,
                        store: store,
                        appState: appState,
                        expandedTagNodes: $expandedTagNodes
                    )
                }
            }
        }
    }

    private func renameTag(_ option: PropertyOption) {
        let alert = NSAlert()
        alert.messageText = "Rename Tag"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = option.name
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                store.renamePropertyOption(option, to: name)
            }
        }
    }
}

// MARK: - Tag Color Palette

private let tagColorPalette: [(name: String, hex: String)] = [
    ("Red",     "E57373"),
    ("Blue",    "64B5F6"),
    ("Green",   "81C784"),
    ("Yellow",  "FFD54F"),
    ("Purple",  "BA68C8"),
    ("Teal",    "4DB6AC"),
    ("Orange",  "FF8A65"),
    ("Gray",    "90A4AE"),
    ("Pink",    "F06292"),
    ("Indigo",  "7986CB"),
    ("Lime",    "AED581"),
    ("Amber",   "FFB74D"),
]

// MARK: - Tag Editor Sheet

private struct TagEditorSheet: View {
    let store: LibraryStore

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var selectedColorHex: String = "E57373"

    var body: some View {
        VStack(spacing: 16) {
            Text("New Tag")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Tag name", text: $name)
                    .textFieldStyle(.roundedBorder)

                Text("Use slash (/) for hierarchy, e.g. \"Research/AI\"")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 24))], spacing: 8) {
                    ForEach(tagColorPalette, id: \.hex) { entry in
                        Button {
                            selectedColorHex = entry.hex
                        } label: {
                            Circle()
                                .fill(Color(hex: entry.hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColorHex == entry.hex ? 2 : 0)
                                        .padding(selectedColorHex == entry.hex ? -2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(entry.name)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty,
                          let tagsProp = store.tagsProperty else { return }
                    store.addPropertyOption(propertyId: tagsProp.id, name: trimmed, colorHex: selectedColorHex)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
