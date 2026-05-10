import SwiftUI

/// A heading entry extracted from markdown content.
struct MarkdownHeading: Identifiable {
    let id = UUID()
    let level: Int      // 1–6
    let title: String
    let lineIndex: Int  // 0-based line number in the source
}

/// Sidebar mode for the markdown viewer.
private enum MarkdownSidebarTab: String, CaseIterable, Identifiable {
    case outline
    case collection

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .outline: return "list.bullet"
        case .collection: return "folder"
        }
    }

    var label: String {
        switch self {
        case .outline: return "Outline"
        case .collection: return "Collection"
        }
    }
}

/// Sidebar view for the markdown viewer with Outline and Collection tabs.
struct MarkdownOutlineSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var activeTab: MarkdownSidebarTab = .outline

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            tabPicker

            switch activeTab {
            case .outline:
                outlineContent
            case .collection:
                collectionContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownSidebarTab.allCases) { tab in
                let selected = activeTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        activeTab = tab
                    }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13))
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
                .help(tab.label)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }

    // MARK: - Outline Content

    private var headings: [MarkdownHeading] {
        Self.extractHeadings(from: viewModel.markdownContent)
    }

    private var outlineContent: some View {
        Group {
            if headings.isEmpty {
                outlineEmptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(headings.enumerated()), id: \.element.id) { index, heading in
                            headingRow(heading, index: index)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func headingRow(_ heading: MarkdownHeading, index: Int) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .markdownScrollToLine,
                object: index
            )
        } label: {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: CGFloat(heading.level - 1) * 14)

                Text(heading.title)
                    .font(.system(size: heading.level <= 2 ? 13 : 12,
                                  weight: heading.level == 1 ? .semibold : .regular))
                    .foregroundStyle(heading.level <= 2 ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var outlineEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(Color.primary.opacity(0.15))

            Text("No Headings")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("Add headings with # syntax\nto build an outline.")
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Collection Content

    /// The collections this item belongs to (non-smart only).
    private var itemCollections: [PDFCollection] {
        viewModel.libraryItem?.collections.filter { !$0.isSmart } ?? []
    }

    /// All items in the same collections as this item.
    private var siblingItems: [(collection: PDFCollection, items: [LibraryItem])] {
        guard let store = viewModel.libraryStore,
              let currentItem = viewModel.libraryItem else { return [] }

        let collections = itemCollections
        if collections.isEmpty { return [] }

        return collections.map { collection in
            let items = store.items
                .filter { item in
                    item.id != currentItem.id &&
                    item.collections.contains(where: { $0.id == collection.id })
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return (collection: collection, items: items)
        }
    }

    private var collectionContent: some View {
        Group {
            let groups = siblingItems
            if itemCollections.isEmpty {
                collectionEmptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.collection.id) { group in
                            collectionSection(group.collection, items: group.items)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func collectionSection(_ collection: PDFCollection, items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collection header
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(collection.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if items.isEmpty {
                Text("No other items")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                ForEach(items) { item in
                    itemRow(item)
                }
            }

            Divider()
                .padding(.vertical, 4)
        }
    }

    private func itemRow(_ item: LibraryItem) -> some View {
        Button {
            viewModel.appState?.openLibraryItem(item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.itemType.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var collectionEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundStyle(Color.primary.opacity(0.15))

            Text("No Collection")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("Add this item to a collection\nto see related files here.")
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Heading Extraction

    static func extractHeadings(from content: String) -> [MarkdownHeading] {
        let lines = content.components(separatedBy: .newlines)
        var headings: [MarkdownHeading] = []
        var inCodeBlock = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            guard !inCodeBlock else { continue }

            guard trimmed.hasPrefix("#") else { continue }

            var level = 0
            for char in trimmed {
                if char == "#" { level += 1 }
                else { break }
            }
            guard level >= 1, level <= 6 else { continue }
            guard trimmed.count > level else { continue }

            let afterHashes = trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)...]
            guard afterHashes.first == " " else { continue }

            let title = afterHashes.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            guard !title.isEmpty else { continue }

            headings.append(MarkdownHeading(level: level, title: title, lineIndex: index))
        }

        return headings
    }
}

// MARK: - Notification

extension Notification.Name {
    static let markdownScrollToLine = Notification.Name("markdownScrollToLine")
}
