import SwiftUI
import PDFKit

struct BookmarkSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var outlineItems: [BookmarkModel] = []
    @State private var selectedItemId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if outlineItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(outlineItems) { item in
                            OutlineTreeRow(
                                item: item,
                                depth: 0,
                                selectedItemId: $selectedItemId,
                                onTap: { tapped in
                                    selectedItemId = tapped.id
                                    viewModel.viewer.goToPage(tapped.pageIndex)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(OakStyle.Colors.sidebarBackground)
        .onAppear { loadOutline() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.indent")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Outline")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This document has no table of contents.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func loadOutline() {
        guard let doc = viewModel.pdfDocument else { return }
        outlineItems = BookmarkModel.models(from: doc)
    }
}

// MARK: - Outline Tree Row (recursive, with expand/collapse)

private struct OutlineTreeRow: View {
    let item: BookmarkModel
    let depth: Int
    @Binding var selectedItemId: UUID?
    let onTap: (BookmarkModel) -> Void

    @State private var isExpanded: Bool = true

    private let indentWidth: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row
            HStack(spacing: 2) {
                // Indent
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * indentWidth)
                }

                // Disclosure triangle
                if !item.children.isEmpty {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture { isExpanded.toggle() }
                } else {
                    Spacer().frame(width: 14)
                }

                Text(item.label)
                    .font(.system(size: 12))
                    .lineLimit(2)

                Spacer()

                Text("\(item.pageIndex + 1)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selectedItemId == item.id ? Color.accentColor.opacity(0.15) : Color.clear)
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
            .onTapGesture { onTap(item) }
            .contextMenu {
                Button("Go to Page") { onTap(item) }
            }

            // Children
            if isExpanded {
                ForEach(item.children) { child in
                    OutlineTreeRow(
                        item: child,
                        depth: depth + 1,
                        selectedItemId: $selectedItemId,
                        onTap: onTap
                    )
                }
            }
        }
    }
}
