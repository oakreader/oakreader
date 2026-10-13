import SwiftUI
import PDFKit

/// Find in the PDF, modelled on Preview: a filled search field, a quiet count with
/// previous / next, and one row per match — the line it sits on with the match in
/// bold, and its page number on the trailing edge. No divider lines; the selected
/// match gets the sidebar's row fill.
struct SearchSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var viewer: ViewerViewModel { viewModel.viewer }
    private var hasQuery: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.top, OakStyle.Spacing.xxs)
                .padding(.bottom, OakStyle.Spacing.xs)

            if hasQuery {
                statusRow
                    .padding(.horizontal, OakStyle.Spacing.sm + 4)
                    .padding(.bottom, OakStyle.Spacing.xxs)
            }

            if viewer.hasSearchResults {
                resultList
            } else {
                Spacer(minLength: 0)
            }
        }
        .onAppear { isSearchFieldFocused = true }
        // Search as the reader types, after a short pause, like Preview.
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await viewer.search(query: searchText)
        }
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)
                .onSubmit { viewer.nextSearchResult() }
                .accessibilityLabel("Search in document")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    viewer.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 2) {
            Group {
                if viewer.isSearching {
                    Text("Searching…")
                } else if viewer.hasSearchResults {
                    Text(viewer.searchResults.count == 1 ? "1 match" : "\(viewer.searchResults.count) matches")
                } else {
                    Text("No matches")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Spacer(minLength: 0)

            if viewer.hasSearchResults {
                stepButton("chevron.up", label: "Previous match") { viewer.previousSearchResult() }
                stepButton("chevron.down", label: "Next match") { viewer.nextSearchResult() }
            }
        }
        .frame(height: 22)
    }

    private func stepButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Results

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(viewer.searchResults.enumerated()), id: \.offset) { index, selection in
                        SearchResultRow(
                            selection: selection,
                            document: viewModel.pdfDocument,
                            isSelected: index == viewer.currentSearchIndex
                        )
                        .id(index)
                        .onTapGesture { viewer.selectSearchResult(at: index) }
                    }
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.bottom, OakStyle.Spacing.sm)
            }
            .onChange(of: viewer.currentSearchIndex) { _, newIndex in
                withAnimation(OakStyle.Motion.slow) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let selection: PDFSelection
    let document: PDFDocument?
    let isSelected: Bool

    /// Built once per row, off `body`: copying and extending a PDFSelection is
    /// PDFKit work, not something to redo on every render.
    @State private var snippet: AttributedString?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(snippet ?? AttributedString(selection.string ?? ""))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let pageNumber {
                Text("\(pageNumber)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? OakStyle.Colors.sidebarRowSelection : .clear)
        )
        .contentShape(Rectangle())
        .task { snippet = Self.snippet(for: selection) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var pageNumber: Int? {
        guard let page = selection.pages.first, let document else { return nil }
        return document.index(for: page) + 1
    }

    /// The line this match sits on, with the match in bold. Extending a copy of
    /// the match's own selection keeps each row on its own occurrence; searching
    /// the page text for the query would show the page's first hit every time.
    private static func snippet(for selection: PDFSelection) -> AttributedString? {
        guard let match = selection.string, !match.isEmpty,
              let context = selection.copy() as? PDFSelection else { return nil }
        context.extendForLineBoundaries()
        let line = (context.string ?? match)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var text = AttributedString(line)
        if let range = text.range(of: match, options: .caseInsensitive) {
            text[range].font = .system(size: 12, weight: .semibold)
        }
        return text
    }
}
