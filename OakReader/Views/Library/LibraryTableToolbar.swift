import SwiftUI
import UniformTypeIdentifiers

// Library toolbar: height 41px, 28x28 buttons, 5px radius
struct LibraryTableToolbar: View {
    let appState: AppState

    @State private var searchText = ""

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(OakStyle.Font.styledCaption)
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .accessibilityHidden(true)
                TextField("Search PDFs", text: $searchText)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search library")
                    .onChange(of: searchText) { _, newValue in
                        store.searchText = newValue
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(OakStyle.Font.styledCaption)
                            .foregroundStyle(Color.primary.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(height: 28)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))

            Spacer()

            // Sort menu
            Menu {
                ForEach(LibrarySortOrder.allCases) { sort in
                    Button {
                        if store.currentSort == sort {
                            store.sortAscending.toggle()
                        } else {
                            store.currentSort = sort
                            store.sortAscending = false
                        }
                    } label: {
                        HStack {
                            Text(sort.rawValue)
                            if store.currentSort == sort {
                                Image(systemName: store.sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: OakStyle.Font.icon))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.clear)
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort Library")
            .accessibilityLabel("Sort Library")

            // Add button
            Button {
                importPDFs()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: OakStyle.Font.icon))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
            }
            .buttonStyle(.borderless)
            .help("Add PDFs to Library")
            .accessibilityLabel("Add PDFs to Library")
        }
        .padding(.horizontal, 8)
        .frame(height: 41)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func importPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Select PDF files to add to your library"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let item = appState.importService.importPDF(from: url) {
                    if let collection = store.selectedCollection, !collection.isSmart {
                        store.addItem(item, to: collection)
                    }
                }
            }
        }
    }
}
