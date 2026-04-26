import SwiftUI
import PDFKit

struct SearchSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: OakStyle.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: OakStyle.Font.icon))
                    .foregroundStyle(.secondary)

                TextField("Find in document...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: OakStyle.Font.body))
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        performSearch()
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        viewModel.viewer.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: OakStyle.Font.icon))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .padding(.top, OakStyle.Spacing.xs)
            .padding(.bottom, OakStyle.Spacing.xxs)

            // Status bar: result count + prev/next
            if viewModel.viewer.isSearching || viewModel.viewer.hasSearchResults || (!searchText.isEmpty && !viewModel.viewer.isSearching) {
                HStack(spacing: OakStyle.Spacing.sm) {
                    if viewModel.viewer.isSearching {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching...")
                            .font(.system(size: OakStyle.Font.caption))
                            .foregroundStyle(.secondary)
                    } else if viewModel.viewer.hasSearchResults {
                        Text(viewModel.viewer.searchResultLabel)
                            .font(.system(size: OakStyle.Font.caption))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No results")
                            .font(.system(size: OakStyle.Font.caption))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if viewModel.viewer.hasSearchResults {
                        Button {
                            viewModel.viewer.previousSearchResult()
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: OakStyle.Font.body, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)

                        Button {
                            viewModel.viewer.nextSearchResult()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: OakStyle.Font.body, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, OakStyle.Spacing.xs)
            }

            Divider()

            // Results list
            if viewModel.viewer.hasSearchResults {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(viewModel.viewer.searchResults.enumerated()), id: \.offset) { index, selection in
                                SearchResultRow(
                                    selection: selection,
                                    document: viewModel.pdfDocument,
                                    isSelected: index == viewModel.viewer.currentSearchIndex
                                )
                                .id(index)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.viewer.currentSearchIndex = index
                                    navigateToResult(selection)
                                }

                                if index < viewModel.viewer.searchResults.count - 1 {
                                    Divider().padding(.leading, 8)
                                }
                            }
                        }
                    }
                    .onChange(of: viewModel.viewer.currentSearchIndex) { _, newIndex in
                        withAnimation {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            } else if !searchText.isEmpty && !viewModel.viewer.isSearching {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("No matches found")
                        .font(.system(size: OakStyle.Font.body))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        }
        .onAppear {
            isSearchFieldFocused = true
        }
    }

    private func performSearch() {
        Task {
            await viewModel.viewer.search(query: searchText)
        }
    }

    private func navigateToResult(_ selection: PDFSelection) {
        guard let page = selection.pages.first,
              let doc = viewModel.pdfDocument else { return }
        let pageIndex = doc.index(for: page)
        viewModel.viewer.goToPage(pageIndex)
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let selection: PDFSelection
    let document: PDFDocument?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let page = selection.pages.first, let doc = document {
                Text("Page \(doc.index(for: page) + 1)")
                    .font(.system(size: OakStyle.Font.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(snippetText)
                .font(.system(size: OakStyle.Font.body))
                .lineLimit(3)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(4)
    }

    private var snippetText: String {
        guard let page = selection.pages.first,
              let pageString = page.string,
              let selString = selection.string, !selString.isEmpty else {
            return selection.string ?? ""
        }

        // Find the match range and extract surrounding context
        let searchRange = pageString.range(of: selString, options: .caseInsensitive)
        guard let matchRange = searchRange else {
            return selString
        }

        let contextChars = 40
        let startDistance = pageString.distance(from: pageString.startIndex, to: matchRange.lowerBound)
        let prefixStart = pageString.index(matchRange.lowerBound, offsetBy: -min(startDistance, contextChars))
        let endDistance = pageString.distance(from: matchRange.upperBound, to: pageString.endIndex)
        let suffixEnd = pageString.index(matchRange.upperBound, offsetBy: min(endDistance, contextChars))

        var snippet = ""
        if prefixStart != pageString.startIndex { snippet += "..." }
        snippet += String(pageString[prefixStart..<suffixEnd])
            .replacingOccurrences(of: "\n", with: " ")
        if suffixEnd != pageString.endIndex { snippet += "..." }

        return snippet
    }
}
