import SwiftUI

struct LibraryToolbarContent: ToolbarContent {
    let appState: AppState

    private var store: LibraryStore { appState.libraryStore }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                importPDFs()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add PDFs to Library")
        }

        ToolbarItem(placement: .primaryAction) {
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
            }
            .help("Sort Library")
        }
    }

    private func importPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Select PDF files to add to your library"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let item = store.addItem(from: url) {
                    if let collection = store.selectedCollection {
                        store.addItem(item, to: collection)
                    }
                    if item.coverImageData == nil {
                        Task {
                            if let data = await appState.coverService.generateCover(for: url) {
                                await MainActor.run { store.updateCover(item, imageData: data) }
                            }
                        }
                    }
                }
            }
        }
    }
}
