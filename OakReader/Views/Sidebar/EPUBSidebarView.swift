import SwiftUI

struct EPUBSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var selectedEntryId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 2) {
                Image(systemName: "list.number")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .foregroundStyle(.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.xs)

            // TOC content
            if let epub = viewModel.epubDocument {
                if epub.tableOfContents.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(epub.tableOfContents) { entry in
                                EPUBTOCRow(
                                    entry: entry,
                                    depth: 0,
                                    selectedEntryId: $selectedEntryId,
                                    onTap: { tapped in
                                        selectedEntryId = tapped.id
                                        if let spineIndex = tapped.spineIndex {
                                            viewModel.state.currentSpineIndex = spineIndex
                                        }
                                        // Always increment token to force reload even if spine index is the same
                                        viewModel.state.epubNavigationToken += 1
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.indent")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Table of Contents")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This EPUB has no navigation entries.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - TOC Row (recursive, with expand/collapse)

private struct EPUBTOCRow: View {
    let entry: EPUBTOCEntry
    let depth: Int
    @Binding var selectedEntryId: UUID?
    let onTap: (EPUBTOCEntry) -> Void

    @State private var isExpanded: Bool = true

    private let indentWidth: CGFloat = 14

    private var isSelected: Bool {
        selectedEntryId == entry.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * indentWidth)
                }

                if !entry.children.isEmpty {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture { isExpanded.toggle() }
                } else {
                    Spacer().frame(width: 14)
                }

                Text(entry.label)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(2)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture { onTap(entry) }

            if isExpanded {
                ForEach(entry.children) { child in
                    EPUBTOCRow(
                        entry: child,
                        depth: depth + 1,
                        selectedEntryId: $selectedEntryId,
                        onTap: onTap
                    )
                }
            }
        }
    }
}
