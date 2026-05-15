import SwiftUI

// Detail panel: tabbed content + side nav icon strip
struct LibrarySidebarPanel: View {
    let item: LibraryItem
    @Bindable var appState: AppState

    @State private var notesVM: NotesViewModel?

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.libraryDetailTab == .chat {
                AIChatView(chatVM: appState.libraryChatVM)
            } else if appState.libraryDetailTab == .notes {
                // NotePanelView manages its own scrolling
                if let notesVM {
                    NotePanelView(notesVM: notesVM)
                }
            } else if appState.libraryDetailTab == .metadata {
                HStack {
                    Text("Metadata")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        infoTabContent
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: item.id) {
            createNotesVM()
        }
        .onChange(of: appState.libraryDetailTab) {
            if appState.libraryDetailTab == .notes && notesVM == nil {
                createNotesVM()
            }
        }
        .onAppear {
            if appState.libraryDetailTab == .notes {
                createNotesVM()
            }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var infoTabContent: some View {
        coverSection

        sectionView(title: "Properties", icon: "tag.fill", iconColor: Color(hex: "E5A540")) {
            propertiesContent
        }

        sectionView(title: "Collections", icon: "folder.fill", iconColor: Color(hex: "59ADC4")) {
            collectionsContent
        }

        metadataSection

        sectionView(title: "File", icon: "doc.fill", iconColor: Color(hex: "8E8E93")) {
            infoGrid
        }

        actionsSection
            .padding(.top, 8)
    }

    // MARK: - Notes VM

    private func createNotesVM() {
        notesVM = NotesViewModel(
            database: store.database,
            storageKey: item.storageKey
        )
    }

    // MARK: - Section wrapper (OakReader collapsible section style)

    @ViewBuilder
    private func sectionView<Content: View>(
        title: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section header — OakReader: icon + semibold title, secondary color
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            .padding(.vertical, 4)

            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)
        }
    }

    // MARK: - Cover

    @ViewBuilder
    private var coverSection: some View {
        if let data = item.coverImageData, let nsImage = NSImage(data: data) {
            HStack {
                Spacer()
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 160)
                    .cornerRadius(4)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: - Reference

    @ViewBuilder
    private var metadataSection: some View {
        if item.referenceMetadata != nil {
            sectionView(title: "Reference", icon: "text.book.closed.fill", iconColor: Color(hex: "4072E5")) {
                ReferenceMetadataView(
                    item: item,
                    store: store,
                    referenceService: appState.referenceService
                )
            }
        } else {
            sectionView(title: "Reference", icon: "text.book.closed.fill", iconColor: Color(hex: "4072E5")) {
                HStack(spacing: 8) {
                    Text("No reference data")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.25))

                    Spacer()

                    Button {
                        createEmptyMetadataForItem()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text("Add")
                                .font(.system(size: 12))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func createEmptyMetadataForItem() {
        var csl = CSLItem(type: "document")
        csl.title = item.title
        if !item.author.isEmpty {
            csl.author = [CSLName(family: item.author, given: nil)]
        }
        do {
            try appState.referenceService.saveMetadata(csl, forItemId: item.id.uuidString)
            store.invalidate()
        } catch {
            Log.error(Log.store, "Failed to create empty reference metadata: \(error)")
        }
    }

    // MARK: - Info Grid (File details)

    @ViewBuilder
    private var infoGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 2) {
            infoGridRow("File", value: item.fileName)
            infoGridRow("Pages", value: "\(item.pageCount)")
            infoGridRow("Size", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
            infoGridRow("Added", value: item.dateAdded.formatted(date: .abbreviated, time: .omitted))
            if let lastOpened = item.lastOpenedAt {
                infoGridRow("Opened", value: lastOpened.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private func infoGridRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.55))
                .gridColumnAlignment(.trailing)

            Text(value)
                .font(.system(size: 13))
                .lineLimit(2)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }

    // MARK: - Properties

    @ViewBuilder
    private var propertiesContent: some View {
        let selectProperties = store.properties.filter { $0.type == .multiSelect || $0.type == .singleSelect }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(selectProperties) { property in
                VStack(alignment: .leading, spacing: 4) {
                    Text(property.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.55))

                    FlowLayout(spacing: 4) {
                        let assignedValues = item.propertyValues.filter { $0.propertyId == property.id }
                        ForEach(assignedValues) { pv in
                            if let opt = pv.option {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: opt.colorHex))
                                        .frame(width: 10, height: 10)
                                    Text(opt.name)
                                        .font(.system(size: 12))
                                    Button {
                                        store.removeItemSelectValue(item: item, property: property, option: opt)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: opt.colorHex).opacity(0.15)))
                            }
                        }

                        // Add option button
                        Menu {
                            PropertyOptionAssignmentMenuItems(
                                item: item,
                                property: property,
                                store: store,
                                mode: .addUnassigned
                            )
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Add")
                                    .font(.system(size: 12))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: - Collections

    @ViewBuilder
    private var collectionsContent: some View {
        if item.collections.isEmpty {
            Text("Not in any collection")
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.25))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(item.collections, id: \.id) { collection in
                    HStack(spacing: 5) {
                        Image(systemName: collection.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.55))
                        Text(collection.name)
                            .font(.system(size: 13))
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        VStack(spacing: 6) {
            Button {
                appState.openLibraryItem(item)
            } label: {
                Label("Open", systemImage: "doc.viewfinder")
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                store.removeItem(item)
            } label: {
                Label("Remove from Library", systemImage: "trash")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
    }
}

enum PropertyOptionAssignmentMenuMode {
    case addUnassigned
    case toggleAssigned
}

struct PropertyOptionAssignmentMenuItems: View {
    let item: LibraryItem
    let property: PropertyDefinition
    let store: LibraryStore
    var mode: PropertyOptionAssignmentMenuMode = .toggleAssigned

    private var assignedOptionIds: Set<UUID> {
        Set(item.propertyValues.compactMap { propertyValue in
            propertyValue.propertyId == property.id ? propertyValue.option?.id : nil
        })
    }

    private var optionNodes: [TagNode] {
        let options: [PropertyOption]
        switch mode {
        case .addUnassigned:
            options = property.options.filter { !assignedOptionIds.contains($0.id) }
        case .toggleAssigned:
            options = property.options
        }

        let pairs = options.map { (option: $0, count: 0) }
        return TagNode.buildHierarchy(from: pairs)
    }

    var body: some View {
        ForEach(optionNodes) { node in
            PropertyOptionAssignmentMenuNodeView(
                node: node,
                item: item,
                property: property,
                store: store,
                assignedOptionIds: assignedOptionIds,
                mode: mode
            )
        }
    }
}

private struct PropertyOptionAssignmentMenuNodeView: View {
    let node: TagNode
    let item: LibraryItem
    let property: PropertyDefinition
    let store: LibraryStore
    let assignedOptionIds: Set<UUID>
    let mode: PropertyOptionAssignmentMenuMode

    private var colorHex: String {
        node.option?.colorHex ?? firstChildColorHex(in: node) ?? "90A4AE"
    }

    var body: some View {
        if node.children.isEmpty {
            if let option = node.option {
                optionButton(option, title: node.name)
            }
        } else {
            Menu {
                if let option = node.option {
                    optionButton(option, title: node.name)
                    Divider()
                }

                ForEach(node.children) { child in
                    PropertyOptionAssignmentMenuNodeView(
                        node: child,
                        item: item,
                        property: property,
                        store: store,
                        assignedOptionIds: assignedOptionIds,
                        mode: mode
                    )
                }
            } label: {
                optionLabel(title: node.name, isAssigned: false)
            }
            .tint(Color(hex: colorHex))
        }
    }

    private func optionButton(_ option: PropertyOption, title: String) -> some View {
        let isAssigned = assignedOptionIds.contains(option.id)

        return Button {
            switch mode {
            case .addUnassigned:
                store.setItemSelectValue(item: item, property: property, option: option)
            case .toggleAssigned:
                if isAssigned {
                    store.removeItemSelectValue(item: item, property: property, option: option)
                } else {
                    store.setItemSelectValue(item: item, property: property, option: option)
                }
            }
        } label: {
            optionLabel(title: title, isAssigned: isAssigned)
        }
        .tint(Color(hex: option.colorHex))
    }

    private func optionLabel(title: String, isAssigned: Bool) -> some View {
        Label(title, systemImage: isAssigned ? "checkmark.circle.fill" : "circle.fill")
    }

    private func firstChildColorHex(in node: TagNode) -> String? {
        for child in node.children {
            if let color = child.option?.colorHex {
                return color
            }
            if let color = firstChildColorHex(in: child) {
                return color
            }
        }
        return nil
    }
}
