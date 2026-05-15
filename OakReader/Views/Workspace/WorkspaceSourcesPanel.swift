import SwiftUI

struct WorkspaceSourcesPanel: View {
    @Bindable var viewModel: WorkspaceViewModel
    let appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sourceList
            Divider()
            footer
        }
        .frame(width: 280)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sources")
                    .font(.system(size: 13, weight: .semibold))
                Text(collectionName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var collectionName: String {
        appState.libraryStore.collections.first { $0.id == viewModel.collectionId }?.name ?? "Collection"
    }

    // MARK: - Source List

    private var sourceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.sourceItems) { item in
                    SourceItemRow(
                        item: item,
                        isSelected: viewModel.selectedSourceIDs.contains(item.id),
                        onToggle: { viewModel.toggleSource(item.id) },
                        onOpen: { appState.openLibraryItem(item) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.selectedSourceIDs.count) of \(viewModel.sourceItems.count) selected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Button("All") {
                viewModel.selectAllSources()
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button("None") {
                viewModel.deselectAllSources()
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Source Item Row

private struct SourceItemRow: View {
    let item: LibraryItem
    let isSelected: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Checkbox
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }

            // Icon
            Image(systemName: item.displayIcon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            // Title
            Text(item.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Type badge
            Text(item.contentType.rawValue.uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.04) : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .onTapGesture(count: 2) { onOpen() }
        .onHover { isHovering = $0 }
    }
}
