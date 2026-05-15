import SwiftUI
import UniformTypeIdentifiers

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
            .help("Add Files to Library")
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
        var contentTypes: [UTType] = [.pdf, .html]
        if let mdType = UTType(filenameExtension: "md") {
            contentTypes.append(mdType)
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Select PDF, HTML, or Markdown files to add to your library"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                let ext = url.pathExtension.lowercased()
                let item: LibraryItem?
                if ext == "html" || ext == "htm" {
                    item = appState.importService.importHTML(from: url)
                } else if ext == "md" || ext == "markdown" {
                    item = appState.importService.importMarkdown(from: url)
                } else {
                    item = appState.importService.importPDF(from: url)
                }
                if let item, let collection = store.selectedCollection, !collection.isSmart {
                    store.addItem(item, to: collection)
                }
            }
        }
    }
}
