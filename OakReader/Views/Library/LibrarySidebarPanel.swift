import SwiftUI

// Detail panel: tabbed content + side nav icon strip
struct LibrarySidebarPanel: View {
    let item: LibraryItem
    @Bindable var appState: AppState

    @State private var metadataTab: MetadataInspectorTab = .info
    @State private var generatedCoverData: Data?

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.libraryDetailTab == .metadata {
                metadataTabPicker
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        switch metadataTab {
                        case .info:
                            infoTabContent
                        case .reference:
                            referenceTabContent
                        }
                    }
                    .padding(OakStyle.Spacing.sm)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: item.id) {
            generatedCoverData = nil
            // Covers are no longer eager-loaded onto the item — read an existing one from disk first.
            if let url = item.primaryAttachment?.coverURL,
               let data = try? Data(contentsOf: url) {
                generatedCoverData = data
                return
            }
            // None on disk → generate one. The sidebar shows a single item, so this is bounded
            // (unlike the card grid, which must never generate covers on scroll).
            let coverService = appState.coverService
            var coverData: Data?
            switch item.contentType {
            case .html:
                coverData = await coverService.generateHTMLCover(for: item.fileURL, sourceURL: item.sourceURL)
            case .link:
                if let sourceURL = item.sourceURL {
                    coverData = await coverService.generateLinkCover(for: sourceURL)
                }
            default:
                break
            }
            if let coverData {
                store.updateCover(item, imageData: coverData)
                generatedCoverData = coverData
            }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var infoTabContent: some View {
        coverSection

        propertiesContent
            .padding(.horizontal, OakStyle.Spacing.xs)

        sectionHeader("Collections")
        collectionsContent
            .padding(.horizontal, OakStyle.Spacing.xs)

        sectionHeader("File")
        infoGrid
            .padding(.horizontal, OakStyle.Spacing.xs)
    }

    @ViewBuilder
    private var referenceTabContent: some View {
        sectionHeader("Reference")
        referenceContent
            .padding(.horizontal, OakStyle.Spacing.xs)
    }

    // MARK: - Metadata tab picker

    private var metadataTabPicker: some View {
        HStack(spacing: 2) {
            ForEach(MetadataInspectorTab.allCases) { tab in
                let selected = metadataTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        metadataTab = tab
                    }
                } label: {
                    Label(tab.label, systemImage: tab.systemImage)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
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
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OakStyle.Colors.textSecondary)
            .padding(.horizontal, OakStyle.Spacing.xs)
            .padding(.top, OakStyle.Spacing.md)
            .padding(.bottom, OakStyle.Spacing.xxs)
    }

    // MARK: - Cover

    @ViewBuilder
    private var coverSection: some View {
        HStack {
            Spacer()
            coverContent
            Spacer()
        }
        .padding(OakStyle.Spacing.xs)
    }

    @ViewBuilder
    private var coverContent: some View {
        if let data = item.coverImageData ?? generatedCoverData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 220)
                .coverCard(shadow: true)
        } else {
            VStack(spacing: OakStyle.Spacing.xs) {
                Image(systemName: item.displayIcon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(item.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(width: 160, height: 160)
            .coverCard(shadow: false)
        }
    }

    // MARK: - Reference

    @ViewBuilder
    private var referenceContent: some View {
        if item.referenceMetadata != nil {
            ReferenceMetadataView(
                item: item,
                store: store,
                referenceService: appState.referenceService
            )
        } else {
            HStack(spacing: OakStyle.Spacing.xs) {
                Text("No reference data")
                    .font(.system(size: 13))
                    .foregroundStyle(OakStyle.Colors.textQuaternary)

                Spacer()

                Button("Add") {
                    createEmptyMetadataForItem()
                }
                .controlSize(.small)
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
        VStack(alignment: .leading, spacing: OakStyle.Spacing.xxs) {
            infoRow("File Name", value: item.fileName)
            infoRow("Pages", value: "\(item.pageCount)")
            infoRow("Size", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
            infoRow("Added", value: item.dateAdded.formatted(date: .abbreviated, time: .omitted))
            if let lastOpened = item.lastOpenedAt {
                infoRow("Opened", value: lastOpened.formatted(date: .abbreviated, time: .omitted))
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(OakStyle.Colors.textSecondary)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Properties

    @ViewBuilder
    private var propertiesContent: some View {
        let selectProperties = store.properties.filter { $0.type == .multiSelect || $0.type == .singleSelect }
        VStack(alignment: .leading, spacing: 20) {
            ForEach(selectProperties) { property in
                VStack(alignment: .leading, spacing: OakStyle.Spacing.xs) {
                    Text(property.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OakStyle.Colors.textSecondary)

                    if property.type == .singleSelect {
                        singleSelectPicker(property)
                    } else {
                        multiSelectTags(property)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func singleSelectPicker(_ property: PropertyDefinition) -> some View {
        let assignedValues = item.propertyValues.filter { $0.propertyId == property.id }
        let selectedOption = assignedValues.first?.option

        Menu {
            // "None" option to clear
            Button {
                if let current = selectedOption {
                    store.removeItemSelectValue(item: item, property: property, option: current)
                }
            } label: {
                if selectedOption == nil {
                    Label("None", systemImage: "checkmark")
                } else {
                    Text("None")
                }
            }

            Divider()

            ForEach(property.options) { opt in
                Button {
                    // Remove current, then set new
                    if let current = selectedOption {
                        store.removeItemSelectValue(item: item, property: property, option: current)
                    }
                    store.setItemSelectValue(item: item, property: property, option: opt)
                } label: {
                    Label {
                        Text(opt.name)
                    } icon: {
                        Image(systemName: selectedOption?.id == opt.id ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
                .tint(Color(hex: opt.colorHex))
            }
        } label: {
            HStack(spacing: OakStyle.Spacing.xxs) {
                if let opt = selectedOption {
                    Circle()
                        .fill(Color(hex: opt.colorHex))
                        .frame(width: 8, height: 8)
                    Text(opt.name)
                        .font(.system(size: 13))
                } else {
                    Text("None")
                        .font(.system(size: 13))
                        .foregroundStyle(OakStyle.Colors.textQuaternary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func multiSelectTags(_ property: PropertyDefinition) -> some View {
        FlowLayout(spacing: OakStyle.Spacing.xxs) {
            let assignedValues = item.propertyValues.filter { $0.propertyId == property.id }
            ForEach(assignedValues) { pv in
                if let opt = pv.option {
                    tagToken(opt, property: property)
                }
            }

            // Add option menu — icon-only compact button
            Menu {
                PropertyOptionAssignmentMenuItems(
                    item: item,
                    property: property,
                    store: store,
                    mode: .toggleAssigned
                )
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(OakStyle.Colors.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: OakStyle.Radius.small)
                            .fill(OakStyle.Colors.buttonBackground)
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func tagToken(_ opt: PropertyOption, property: PropertyDefinition) -> some View {
        HStack(spacing: OakStyle.Spacing.xxs) {
            Circle()
                .fill(Color(hex: opt.colorHex))
                .frame(width: 8, height: 8)
            Text(opt.name)
                .font(.system(size: 13))
        }
        .padding(.horizontal, OakStyle.Spacing.xs)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: OakStyle.Radius.small)
                .fill(Color(hex: opt.colorHex).opacity(0.12))
        )
        .contextMenu {
            Button("Remove", role: .destructive) {
                store.removeItemSelectValue(item: item, property: property, option: opt)
            }
        }
    }

    // MARK: - Collections

    @ViewBuilder
    private var collectionsContent: some View {
        if item.collections.isEmpty {
            Text("None")
                .font(.system(size: 13))
                .foregroundStyle(OakStyle.Colors.textQuaternary)
        } else {
            VStack(alignment: .leading, spacing: OakStyle.Spacing.xxs) {
                ForEach(item.collections, id: \.id) { collection in
                    HStack(spacing: OakStyle.Spacing.xxs) {
                        Image(systemName: collection.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(OakStyle.Colors.textSecondary)
                        Text(collection.name)
                            .font(.system(size: 13))
                    }
                }
            }
        }
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
