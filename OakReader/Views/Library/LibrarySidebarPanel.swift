import SwiftUI

// Detail panel: collapsible sections with colored icons,
// grid metadata layout with 8px column gap, 2px row gap, secondary labels at 55% opacity
struct LibrarySidebarPanel: View {
    let item: PDFLibraryItem
    let appState: AppState

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                // Header: cover + title
                headerSection
                    .padding(.bottom, 8)

                // Info section
                sectionView(title: "Info", icon: "info.circle.fill", iconColor: Color(hex: "4072E5")) {
                    infoGrid
                }

                // Reference section
                sectionView(title: "Reference", icon: "quote.opening", iconColor: Color(hex: "8B5CF6")) {
                    ReferenceMetadataView(
                        item: item,
                        store: store,
                        referenceService: appState.referenceService
                    )
                }

                // Tags section
                sectionView(title: "Tags", icon: "tag.fill", iconColor: Color(hex: "FF794C")) {
                    tagsContent
                }

                // Collections section
                sectionView(title: "Collections", icon: "folder.fill", iconColor: Color(hex: "59ADC4")) {
                    collectionsContent
                }

                // Actions
                actionsSection
                    .padding(.top, 8)
            }
            .padding(8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: "F2F2F2"))
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
            if let lastOpened = item.dateLastOpened {
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

    // MARK: - Tags

    @ViewBuilder
    private var tagsContent: some View {
        FlowLayout(spacing: 4) {
            ForEach(item.tags, id: \.id) { tag in
                TagChip(
                    name: tag.name,
                    colorHex: tag.colorHex,
                    showRemove: true,
                    onRemove: {
                        store.removeTag(tag, from: item)
                    }
                )
            }

            // Add tag button
            Menu {
                ForEach(store.tags.filter { tag in
                    !item.tags.contains(where: { $0.id == tag.id })
                }, id: \.id) { tag in
                    Button {
                        store.addTag(tag, to: item)
                    } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: tag.colorHex))
                                .frame(width: 10, height: 10)
                            Text(tag.name)
                        }
                    }
                }

                if store.tags.isEmpty || store.tags.allSatisfy({ tag in item.tags.contains(where: { $0.id == tag.id }) }) {
                    Text("No more tags available")
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
