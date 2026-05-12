import SwiftUI

/// Panel shown in the detail area when the Duplicates collection is selected.
/// Shows duplicate group info and a merge interface when a group is selected.
struct DuplicatesMergePane: View {
    @Bindable var appState: AppState

    private var store: LibraryStore { appState.libraryStore }

    private var groups: [[LibraryItem]] { store.duplicateGroups }

    /// Find the group that contains any of the selected items.
    private var selectedGroup: [LibraryItem]? {
        let selected = appState.selectedLibraryItemIDs
        guard !selected.isEmpty else { return nil }
        return groups.first { group in
            group.contains { selected.contains($0.id) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let group = selectedGroup {
                MergeGroupView(group: group, appState: appState)
            } else {
                overviewContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicates")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(groups.count) sets of duplicates found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Overview

    private var overviewContent: some View {
        Group {
            if groups.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No Duplicates")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Your library has no duplicate items.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        Text("Select an item in the table to see its duplicate group and merge options.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
        }
    }
}

// MARK: - Merge Group View

private struct MergeGroupView: View {
    let group: [LibraryItem]
    @Bindable var appState: AppState

    @State private var keeperId: UUID?

    private var store: LibraryStore { appState.libraryStore }

    /// Items sorted by date added (oldest first = likely the "original").
    private var sortedGroup: [LibraryItem] {
        group.sorted { $0.dateAdded < $1.dateAdded }
    }

    private var effectiveKeeperId: UUID {
        keeperId ?? sortedGroup.first?.id ?? UUID()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                groupHeader
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(sortedGroup) { item in
                    itemRow(item)
                }

                fieldComparison
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                actionButtons
                    .padding(12)
            }
        }
    }

    // MARK: - Group Header

    private var groupHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(group.count) duplicate items")
                .font(.system(size: 13, weight: .semibold))
            Text("Select which item to keep. Attachments, tags, and notes from the others will be transferred to it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Item Row

    private func itemRow(_ item: LibraryItem) -> some View {
        let isKeeper = item.id == effectiveKeeperId

        return Button {
            keeperId = item.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isKeeper ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isKeeper ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: item.displayIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .font(.system(size: 13, weight: isKeeper ? .semibold : .regular))
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if !item.author.isEmpty {
                            Text(item.author)
                        }
                        Text(item.dateAdded.formatted(date: .abbreviated, time: .omitted))
                        Text("\(item.attachments.count) files")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if isKeeper {
                    Text("Keep")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isKeeper ? Color.blue.opacity(0.05) : Color.clear)
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Field Comparison

    private var fieldComparison: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comparison")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            comparisonGrid
        }
    }

    private var comparisonGrid: some View {
        let fields: [(label: String, values: [String])] = [
            ("Title", sortedGroup.map { $0.title }),
            ("Author", sortedGroup.map { $0.author }),
            ("Year", sortedGroup.map { $0.referenceMetadata?.year.map { "\($0)" } ?? "-" }),
            ("DOI", sortedGroup.map { $0.referenceMetadata?.doi ?? "-" }),
            ("Attachments", sortedGroup.map { "\($0.attachments.count)" }),
            ("Date Added", sortedGroup.map { $0.dateAdded.formatted(date: .abbreviated, time: .shortened) }),
        ]

        return VStack(spacing: 0) {
            ForEach(fields.indices, id: \.self) { index in
                let field = fields[index]
                let allSame = Set(field.values).count <= 1

                HStack(alignment: .top, spacing: 8) {
                    Text(field.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sortedGroup.indices, id: \.self) { i in
                            let isKeeper = sortedGroup[i].id == effectiveKeeperId
                            Text(field.values[i])
                                .font(.system(size: 11, weight: isKeeper ? .medium : .regular))
                                .foregroundStyle(allSame ? .secondary : .primary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 4)

                if index < fields.count - 1 {
                    Divider()
                        .padding(.leading, 80)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("Skip") {
                moveToNextGroup()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                performMerge()
            } label: {
                Text("Merge \(group.count) Items")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func performMerge() {
        guard let keeper = sortedGroup.first(where: { $0.id == effectiveKeeperId }) else { return }
        let toMerge = sortedGroup.filter { $0.id != keeper.id }
        store.mergeItems(keeper: keeper, duplicates: toMerge)
        appState.selectedLibraryItemIDs = []
    }

    private func moveToNextGroup() {
        let groups = store.duplicateGroups
        guard let currentGroup = groups.first(where: { g in
            g.contains { appState.selectedLibraryItemIDs.contains($0.id) }
        }) else {
            appState.selectedLibraryItemIDs = []
            return
        }
        if let idx = groups.firstIndex(where: { $0.first?.id == currentGroup.first?.id }),
           idx + 1 < groups.count,
           let nextFirst = groups[idx + 1].first {
            appState.selectedLibraryItemIDs = [nextFirst.id]
        } else {
            appState.selectedLibraryItemIDs = []
        }
    }
}
