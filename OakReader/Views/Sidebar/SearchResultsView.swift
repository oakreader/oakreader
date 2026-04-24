import SwiftUI
import PDFKit

struct SearchBarView: View {
    let viewModel: DocumentViewModel

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        HStack(spacing: OakStyle.Spacing.xs) {
            // Search field
            HStack(spacing: 5) {
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
                            .font(.system(size: OakStyle.Font.iconSmall))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(OakStyle.Radius.standard)
            .frame(maxWidth: 260)

            // Result count
            if viewModel.viewer.hasSearchResults {
                Text(viewModel.viewer.searchResultLabel)
                    .font(.system(size: OakStyle.Font.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else if !searchText.isEmpty && !viewModel.viewer.isSearching {
                Text("No results")
                    .font(.system(size: OakStyle.Font.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if viewModel.viewer.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            // Prev / Next
            if viewModel.viewer.hasSearchResults {
                Button {
                    viewModel.viewer.previousSearchResult()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: OakStyle.Font.iconSmall))
                }
                .buttonStyle(.borderless)

                Button {
                    viewModel.viewer.nextSearchResult()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: OakStyle.Font.iconSmall))
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            // Close
            Button {
                viewModel.state.isSearchBarVisible = false
                viewModel.viewer.clearSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: OakStyle.Font.iconSmall))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, OakStyle.Spacing.xs)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            isSearchFieldFocused = true
        }
    }

    private func performSearch() {
        Task {
            await viewModel.viewer.search(query: searchText)
        }
    }
}
