import SwiftUI
import PDFKit

struct BookmarkSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var outlineItems: [BookmarkModel] = []
    @State private var userBookmarks: [BookmarkModel] = []
    @State private var showAddBookmark = false
    @State private var newBookmarkLabel = ""
    @State private var selectedItemId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if outlineItems.isEmpty && userBookmarks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // PDF Outline section (read-only)
                        if !outlineItems.isEmpty {
                            SectionHeader(title: "Outline")
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

                        // User Bookmarks section (editable)
                        SectionHeader(title: "Bookmarks")
                        if userBookmarks.isEmpty {
                            Text("No bookmarks yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(userBookmarks) { bookmark in
                                BookmarkRow(
                                    bookmark: bookmark,
                                    isSelected: selectedItemId == bookmark.id,
                                    onTap: {
                                        selectedItemId = bookmark.id
                                        viewModel.viewer.goToPage(bookmark.pageIndex)
                                    },
                                    onDelete: {
                                        removeBookmark(bookmark)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            HStack {
                Button {
                    showAddBookmark = true
                } label: {
                    Label("Add Bookmark", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()
            }
            .padding(8)
        }
        .background(ZoteroStyle.Colors.sidebarBackground)
        .onAppear { loadOutline() }
        .sheet(isPresented: $showAddBookmark) {
            addBookmarkSheet
        }
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

    // MARK: - Add Bookmark Sheet

    private var addBookmarkSheet: some View {
        VStack(spacing: 16) {
            Text("Add Bookmark")
                .font(.headline)

            TextField("Bookmark Name", text: $newBookmarkLabel)
                .textFieldStyle(.roundedBorder)

            Text("For page \(viewModel.state.currentPageIndex + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    showAddBookmark = false
                    newBookmarkLabel = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    addBookmark()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBookmarkLabel.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: - Actions

    private func loadOutline() {
        guard let doc = viewModel.pdfDocument else { return }
        outlineItems = BookmarkModel.models(from: doc)
    }

    private func addBookmark() {
        let bookmark = BookmarkModel(
            label: newBookmarkLabel.isEmpty ? "Page \(viewModel.state.currentPageIndex + 1)" : newBookmarkLabel,
            pageIndex: viewModel.state.currentPageIndex
        )
        userBookmarks.append(bookmark)
        newBookmarkLabel = ""
        showAddBookmark = false
    }

    private func removeBookmark(_ bookmark: BookmarkModel) {
        userBookmarks.removeAll { $0.id == bookmark.id }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
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
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
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

// MARK: - Bookmark Row

private struct BookmarkRow: View {
    let bookmark: BookmarkModel
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 10))
            Text(bookmark.label)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
            Text("\(bookmark.pageIndex + 1)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
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
        .onTapGesture { onTap() }
        .contextMenu {
            Button("Go to Page") { onTap() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}
