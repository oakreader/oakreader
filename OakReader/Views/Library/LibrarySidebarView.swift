import SwiftUI

struct LibrarySidebarView: View {
    let appState: AppState

    @State private var sidebarMode: LibrarySidebarMode = .collections
    @State private var showNewCollection = false
    @State private var showNewSmartCollection = false
    @State private var newSubcollectionParent: PDFCollection?
    @State private var expandedCollections: Set<UUID> = []
    @State private var expandedTagNodes: Set<UUID> = []
    @State private var editingSmartCollection: PDFCollection?

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            myLibrarySection

            Spacer().frame(height: 14)

            // Grouped section: tabs + list in a bordered container
            VStack(spacing: 0) {
                sectionSwitcher

                switch sidebarMode {
                case .collections:
                    collectionsScrollView
                case .tags:
                    tagsScrollView
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 10)

            Spacer()
        }
        .background(OakStyle.Colors.sidebarBackground)
        .sheet(isPresented: $showNewCollection) {
            CollectionEditorSheet(store: store, collection: nil)
        }
        .sheet(isPresented: $showNewSmartCollection) {
            SmartCollectionEditorSheet(store: store, collection: nil)
        }
        .sheet(item: $editingSmartCollection) { collection in
            SmartCollectionEditorSheet(store: store, collection: collection)
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
        let count = store.importFolder(url, importService: appState.importService)
        Log.info(Log.ui, "Imported \(count) items from folder: \(url.lastPathComponent)")
    }

    // MARK: - Smart Collection Row

    private func smartCollectionRow(_ collection: PDFCollection) -> some View {
        let isSelected = store.selectedCollectionId == collection.id && store.selectedTagOptionId == nil && appState.isLibraryActive
        let isInbox = collection.id == SystemCollectionID.inbox
        let count = isInbox ? store.inboxCount : store.smartCollectionItemCount(for: collection)

        return Button {
            store.selectCollection(collection.id)
            appState.switchToLibrary()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collection.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .frame(width: 20)

                Text(collection.name)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if isInbox && count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collection.name)
    }
}

// MARK: - Subviews

private extension LibrarySidebarView {
    var myLibrarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("MY LIBRARY")

            ForEach(store.systemSmartCollections.sorted(by: { $0.sortOrder < $1.sortOrder })) { collection in
                if !store.hiddenSystemCollectionIds.contains(collection.id) {
                    smartCollectionRow(collection)
                }
            }
        }
    }

    var sectionSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(LibrarySidebarMode.allCases) { mode in
                let selected = sidebarMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sidebarMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 11))
                        Text(mode.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .foregroundStyle(selected ? .white : .secondary)
                    .background(
                        Capsule()
                            .fill(selected ? Color.accentColor : .clear)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
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
            }
        }
        .id(store.revision)
        .contextMenu {
            Button("New Tag...") {
                showNewTag()
            }
        }
    }

    private static let tagColorPalette: [(name: String, hex: String)] = [
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

    func showNewTag() {
        guard let tagsProp = store.tagsProperty else { return }

        let alert = NSAlert()
        alert.messageText = "New Tag"
        alert.informativeText = "Use slash (/) for hierarchy, e.g. \"Research/AI\""
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        // Container for name field + color picker
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 68))

        let textField = NSTextField(frame: NSRect(x: 0, y: 42, width: 260, height: 24))
        textField.placeholderString = "Tag name"
        container.addSubview(textField)

        // Color picker row
        let palette = Self.tagColorPalette
        let dotSize: CGFloat = 18
        let spacing: CGFloat = 4
        var selectedIndex = 0

        let colorContainer = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 34))

        var colorButtons: [NSButton] = []
        for (i, entry) in palette.enumerated() {
            let x = CGFloat(i) * (dotSize + spacing)
            let btn = NSButton(frame: NSRect(x: x, y: 6, width: dotSize, height: dotSize))
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.title = ""
            btn.wantsLayer = true
            btn.layer?.cornerRadius = dotSize / 2
            btn.layer?.masksToBounds = true
            btn.layer?.backgroundColor = NSColor(hex: entry.hex)?.cgColor
            btn.layer?.borderWidth = i == 0 ? 2 : 0
            btn.layer?.borderColor = NSColor.controlAccentColor.cgColor
            btn.tag = i
            btn.target = colorContainer
            colorButtons.append(btn)
            colorContainer.addSubview(btn)
        }

        // Use a helper class for color selection
        let colorSelector = TagColorSelector(buttons: colorButtons)
        colorContainer.subviews.forEach { view in
            if let btn = view as? NSButton {
                btn.target = colorSelector
                btn.action = #selector(TagColorSelector.selectColor(_:))
            }
        }

        container.addSubview(colorContainer)
        alert.accessoryView = container

        // Keep selector alive during the modal
        let _ = withExtendedLifetime(colorSelector) {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }

            selectedIndex = colorSelector.selectedIndex
            let color = palette[selectedIndex].hex
            store.addPropertyOption(propertyId: tagsProp.id, name: name, colorHex: color)
        }
    }

    var collectionsScrollView: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(store.rootCollections.sorted(by: { $0.sortOrder < $1.sortOrder })) { collection in
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

    private var isSelected: Bool {
        store.selectedCollectionId == collection.id && store.selectedTagOptionId == nil && appState.isLibraryActive
    }

    private var hasChildren: Bool {
        !collection.subcollections.isEmpty
    }

    private var isExpanded: Bool {
        expandedCollections.contains(collection.id)
    }

    private var displayCount: Int {
        if collection.isSmart {
            return store.smartCollectionItemCount(for: collection)
        }
        return collection.itemCount
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                store.selectCollection(collection.id)
                appState.switchToLibrary()
            } label: {
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: CGFloat(depth) * 18)

                    // Disclosure triangle (static image, toggle handled by overlay)
                    if hasChildren {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    } else {
                        Spacer().frame(width: 16)
                    }

                    Image(systemName: collection.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .frame(width: 20)
                        .padding(.trailing, 6)

                    Text(collection.name)
                        .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    let count = displayCount
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                        .padding(.horizontal, 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) {
                if hasChildren {
                    Color.clear
                        .frame(width: CGFloat(depth) * 18 + 16 + 20, height: 34)
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
            .contextMenu {
                if collection.isSmart && !collection.isSystem {
                    Button("Edit Smart Collection...") {
                        editingSmartCollection = collection
                    }
                }
                if !collection.isSystem {
                    Button("Rename...") {
                        renameCollection(collection)
                    }
                }
                if !collection.isSmart {
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
                }
                if !collection.isSystem {
                    Divider()
                    Button("Delete", role: .destructive) {
                        store.deleteCollection(collection)
                    }
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
                        newSubcollectionParent: $newSubcollectionParent,
                        editingSmartCollection: $editingSmartCollection
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

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if let option = node.option {
                    store.selectTag(option.id)
                    appState.switchToLibrary()
                } else if hasChildren {
                    // Intermediate node: toggle expand
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded {
                            expandedTagNodes.remove(node.id)
                        } else {
                            expandedTagNodes.insert(node.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: CGFloat(depth) * 18)

                    if hasChildren {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    } else {
                        Spacer().frame(width: 16)
                    }

                    // Color indicator
                    if let option = node.option {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: option.colorHex))
                            .frame(width: 12, height: 12)
                            .padding(.trailing, 6)
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                            .padding(.trailing, 6)
                    }

                    Text(node.name)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    let total = node.totalCount()
                    if total > 0 {
                        Text("\(total)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                        .padding(.horizontal, 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) {
                if hasChildren {
                    Color.clear
                        .frame(width: CGFloat(depth) * 18 + 16 + 20, height: 34)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isExpanded {
                                    expandedTagNodes.remove(node.id)
                                } else {
                                    expandedTagNodes.insert(node.id)
                                }
                            }
                        }
                }
            }
            .contextMenu {
                if let option = node.option {
                    Button("Rename...") {
                        renameTag(option)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        store.removePropertyOption(option)
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

// MARK: - Tag Color Selector

private class TagColorSelector: NSObject {
    let buttons: [NSButton]
    var selectedIndex: Int = 0

    init(buttons: [NSButton]) {
        self.buttons = buttons
    }

    @objc func selectColor(_ sender: NSButton) {
        selectedIndex = sender.tag
        for (i, btn) in buttons.enumerated() {
            btn.layer?.borderWidth = i == selectedIndex ? 2 : 0
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
