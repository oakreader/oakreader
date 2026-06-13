import SwiftUI

/// A heading extracted from a live web page's DOM.
struct WebHeading: Identifiable, Decodable, Equatable {
    let level: Int        // 1–6 (the heading tag level)
    let title: String
    let elementId: String // DOM id used to scroll the page to this heading

    var id: String { elementId }
}

/// The two modes the live-web sidebar can show, mirroring the PDF sidebar's
/// tab-style mode picker.
private enum WebSidebarMode: String, CaseIterable, Identifiable {
    case contents
    case search

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .contents: return "list.bullet.indent"
        case .search:   return "magnifyingglass"
        }
    }

    var label: String {
        switch self {
        case .contents: return "Contents"
        case .search:   return "Search"
        }
    }
}

/// Left sidebar for web content — both live `.link` browser tabs and `.html`
/// snapshots, which render through the same WKWebView. Mirrors the PDF
/// `SidebarView`: a tab-style mode picker at the top switching between the
/// page's heading outline (Contents) and find-in-page (Search).
struct WebTOCSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var mode: WebSidebarMode = .contents

    var body: some View {
        VStack(spacing: 0) {
            modePicker

            switch mode {
            case .contents:
                WebContentsView(viewModel: viewModel)
            case .search:
                WebSearchView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(WebSidebarMode.allCases) { item in
                let selected = mode == item
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mode = item
                    }
                } label: {
                    Image(systemName: item.systemImage)
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
                .help(item.label)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }
}

// MARK: - Contents (TOC)

/// The page's heading outline. Tapping a heading scrolls the underlying
/// WKWebView to it.
private struct WebContentsView: View {
    let viewModel: DocumentViewModel

    @State private var selectedId: String?

    private var headings: [WebHeading] { viewModel.state.tableOfContents }

    /// Normalize indentation against the shallowest heading present so pages that
    /// start at h2/h3 aren't pushed to the right.
    private var minLevel: Int { headings.map(\.level).min() ?? 1 }

    var body: some View {
        if headings.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(headings) { heading in
                        row(heading)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }

    private func row(_ heading: WebHeading) -> some View {
        let depth = max(0, heading.level - minLevel)
        return Button {
            selectedId = heading.id
            NotificationCenter.default.post(
                name: .webViewScrollToTOC,
                object: viewModel,
                userInfo: ["id": heading.elementId]
            )
        } label: {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: CGFloat(depth) * 12)

                Text(heading.title)
                    .font(.system(size: depth == 0 ? 13 : 12,
                                  weight: depth == 0 ? .semibold : .regular))
                    .foregroundStyle(depth == 0 ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selectedId == heading.id ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(Color.primary.opacity(0.15))

            Text("No Contents")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("This page has no headings\nto build a table of contents.")
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search (find in page)

/// Find-in-page for the live web view, mirroring the PDF `SearchSidebarView`.
/// Submitting marks every match via the mark.js bridge in `WebViewCoordinator`;
/// the prev/next buttons step the active match. Counts come back through
/// `DocumentState`.
private struct WebSearchView: View {
    let viewModel: DocumentViewModel

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var matchCount: Int { viewModel.state.webSearchMatchCount }
    private var currentMatch: Int { viewModel.state.webSearchCurrentMatch }
    private var hasResults: Bool { matchCount > 0 }
    private var hasSearched: Bool { !searchText.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if hasSearched {
                statusBar
            }

            Divider()

            if !hasResults && hasSearched {
                noResults
            } else {
                Spacer()
            }
        }
        .onAppear { isSearchFieldFocused = true }
        .onDisappear { clear() }
    }

    private var searchField: some View {
        HStack(spacing: OakStyle.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: OakStyle.Font.icon))
                .foregroundStyle(.secondary)

            TextField("Find on page...", text: $searchText)
                .textFieldStyle(.plain)
                .font(OakStyle.Font.styledBody)
                .focused($isSearchFieldFocused)
                .onSubmit { performSearch() }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    clear()
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
    }

    private var statusBar: some View {
        HStack(spacing: OakStyle.Spacing.sm) {
            if hasResults {
                Text("\(currentMatch) of \(matchCount)")
                    .font(OakStyle.Font.styledCaption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No results")
                    .font(OakStyle.Font.styledCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if hasResults {
                Button {
                    NotificationCenter.default.post(name: .webViewFindPrev, object: viewModel)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Button {
                    NotificationCenter.default.post(name: .webViewFindNext, object: viewModel)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, OakStyle.Spacing.xs)
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No matches found")
                .font(OakStyle.Font.styledBody)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clear(); return }
        NotificationCenter.default.post(
            name: .webViewFindInPage,
            object: viewModel,
            userInfo: ["text": query]
        )
    }

    private func clear() {
        viewModel.state.webSearchMatchCount = 0
        viewModel.state.webSearchCurrentMatch = 0
        NotificationCenter.default.post(name: .webViewClearFind, object: viewModel)
    }
}
