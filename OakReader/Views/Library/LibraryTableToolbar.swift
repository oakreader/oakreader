import SwiftUI
import UniformTypeIdentifiers

// Library toolbar: height 41px, 28x28 buttons, 5px radius
struct LibraryTableToolbar: View {
    let appState: AppState

    @State private var searchText = ""
    @State private var showFilterPopover = false

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        VStack(spacing: 0) {
            // Main toolbar row
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

                // Filter button
                Button {
                    showFilterPopover.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: OakStyle.Font.icon))
                        .foregroundStyle(store.hasActiveFilters ? Color.accentColor : Color.primary.opacity(0.55))
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                }
                .buttonStyle(.borderless)
                .help("Filter Library")
                .accessibilityLabel("Filter Library")
                .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
                    LibraryFilterPopover(store: store)
                }

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
                .help("Add Files to Library")
                .accessibilityLabel("Add Files to Library")
            }
            .padding(.horizontal, 8)
            .frame(height: 41)

            // Filter pills row
            if store.hasActiveFilters {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.activeFilters.indices, id: \.self) { index in
                            FilterPillView(
                                label: store.activeFilters[index].displayLabel(store: store)
                            ) {
                                store.activeFilters.remove(at: index)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                    item = appState.importService.importWebSnapshot(from: url)
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
