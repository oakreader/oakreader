import SwiftUI

// Detail panel: header + tabbed content + side nav icon strip
struct LibrarySidebarPanel: View {
    let item: LibraryItem
    @Bindable var appState: AppState

    @State private var notes: [Note] = []

    private var store: LibraryStore { appState.libraryStore }
    private var noteService: NoteService { NoteService(database: store.database) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: cover + title + author
            headerSection
                .padding(.bottom, 8)

            Divider()

            // Tabbed content
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    switch appState.libraryDetailTab {
                    case .info:
                        infoTabContent
                    case .reference:
                        referenceTabContent
                    case .properties:
                        propertiesTabContent
                    case .notes:
                        notesTabContent
                    case .chat:
                        EmptyView()
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: item.id) {
            loadNotes()
        }
        .onChange(of: appState.libraryDetailTab) {
            if appState.libraryDetailTab == .notes {
                loadNotes()
            }
        }
        .onAppear {
            if appState.libraryDetailTab == .notes {
                loadNotes()
            }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var infoTabContent: some View {
        sectionView(title: "Info", icon: "info.circle.fill", iconColor: Color(hex: "4072E5")) {
            infoGrid
        }

        sectionView(title: "Collections", icon: "folder.fill", iconColor: Color(hex: "59ADC4")) {
            collectionsContent
        }

        actionsSection
            .padding(.top, 8)
    }

    @ViewBuilder
    private var referenceTabContent: some View {
        ReferenceMetadataView(
            item: item,
            store: store,
            referenceService: appState.referenceService
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var propertiesTabContent: some View {
        propertiesContent
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private var notesTabContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.primary.opacity(0.20))
                    Text("No notes")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.35))
                    Text("Open the document to create notes")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.25))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(notes) { note in
                    noteRow(note)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Note row

    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.45))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)
        }
    }

    // MARK: - Notes loading

    private func loadNotes() {
        do {
            notes = try noteService.fetchNotes(forItemId: item.id.uuidString)
        } catch {
            notes = []
        }
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

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 8) {
            // Cover
            HStack {
                Spacer()
                if let data = item.coverImageData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 160)
                        .cornerRadius(4)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.06))
                        Image(systemName: "doc.text")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.primary.opacity(0.25))
                    }
                    .frame(width: 100, height: 140)
                }
                Spacer()
            }

            // Title — OakReader: semibold, line-height 1.333
            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Author — OakReader: secondary color
            if !item.author.isEmpty {
                Text(item.author)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(8)
    }

    // MARK: - Info Grid (OakReader: CSS Grid, max-content 1fr, gap 8px col / 2px row)

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
                            let assignedOptionIds = Set(assignedValues.compactMap { $0.option?.id })
                            ForEach(property.options.filter { !assignedOptionIds.contains($0.id) }) { option in
                                Button {
                                    store.setItemSelectValue(item: item, property: property, option: option)
                                } label: {
                                    HStack {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color(hex: option.colorHex))
                                            .frame(width: 10, height: 10)
                                        Text(option.name)
                                    }
                                }
                            }
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
