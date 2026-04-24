import SwiftUI
import UniformTypeIdentifiers

// Zotero-style toolbar: height 41px, sidepane bg, 28x28 buttons, 5px radius
struct LibraryTableToolbar: View {
    let appState: AppState

    @State private var searchText = ""

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        HStack(spacing: 8) {
            // Search field — Zotero style: height 28, radius 5
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.55))
                TextField("Search PDFs", text: $searchText)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) { _, newValue in
                        store.searchText = newValue
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(height: 28)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))

            Spacer()

            // Sort menu — Zotero: 28x28, radius 5
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
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.clear)
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort Library")

            // Add button — Zotero: 28x28, radius 5
            Button {
                importPDFs()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Add PDFs to Library")
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
                    if let collection = store.selectedCollection {
                        store.addItem(item, to: collection)
                    }
                }
            }
        }
    }
}
