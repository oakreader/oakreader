import SwiftUI
import UniformTypeIdentifiers

// Library toolbar: height 41px, 28x28 buttons, 6px radius
struct LibraryTableToolbar: View {
    let appState: AppState

    @State private var searchText = ""
    @State private var showingAddSources = false

    private var store: LibraryStore { appState.libraryStore }

    private var statusProperty: PropertyDefinition? {
        store.properties.first { $0.name == "Status" && $0.isSystem }
    }

    private let filterableTypes: [(type: ContentType, label: String)] = [
        (.pdf, "PDF"),
        (.html, "Web"),
        (.video, "Embed"),
        (.markdown, "Note"),
        (.audio, "Audio"),
    ]

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
                    TextField("Search Library", text: $searchText)
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
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                Spacer()

                // Filter menu
                Menu {
                    filterMenuContent
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: OakStyle.Font.icon))
                        .foregroundStyle(
                            store.hasActiveFilters
                                ? Color.accentColor
                                : Color.primary.opacity(0.55)
                        )
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter Library")
                .accessibilityLabel("Filter Library")

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

                // Add sources button
                Button {
                    showingAddSources = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: OakStyle.Font.icon))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                }
                .buttonStyle(.borderless)
                .help("Add Sources to Library")
                .accessibilityLabel("Add Sources to Library")
            }
            .padding(.horizontal, 8)
            .frame(height: 41)

        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingAddSources) {
            AddSourcesSheet(appState: appState)
        }
    }

    @ViewBuilder
    private var filterMenuContent: some View {
        Menu("Type") {
            ForEach(filterableTypes, id: \.type) { entry in
                Button {
                    toggleType(entry.type.rawValue)
                } label: {
                    Label(
                        entry.label,
                        systemImage: store.selectedTypes.contains(entry.type.rawValue)
                            ? "checkmark.circle.fill"
                            : entry.type.icon
                    )
                }
            }
        }

        if let tagsProp = store.tagsProperty, !tagsProp.options.isEmpty {
            Menu("Tags") {
                ForEach(tagsProp.options) { option in
                    Button {
                        toggleTagOption(option.id)
                    } label: {
                        optionFilterLabel(
                            option,
                            isSelected: store.selectedTagOptionIds.contains(option.id)
                        )
                    }
                }
            }
        }

        if let statusProp = statusProperty, !statusProp.options.isEmpty {
            Menu("Status") {
                ForEach(statusProp.options) { option in
                    Button {
                        toggleStatusOption(option.id)
                    } label: {
                        optionFilterLabel(
                            option,
                            isSelected: store.selectedStatusOptionIds.contains(option.id)
                        )
                    }
                }
            }
        }

        if store.hasActiveFilters {
            Divider()
            Button("Clear Filters") {
                store.clearFilters()
            }
        }
    }

    private func optionFilterLabel(_ option: PropertyOption, isSelected: Bool) -> some View {
        Label(
            option.name,
            systemImage: isSelected ? "checkmark.circle.fill" : "circle.fill"
        )
        .tint(Color(hex: option.colorHex))
    }

    private func toggleType(_ rawValue: String) {
        if store.selectedTypes.contains(rawValue) {
            store.selectedTypes.remove(rawValue)
        } else {
            store.selectedTypes.insert(rawValue)
        }
    }

    private func toggleTagOption(_ id: UUID) {
        if store.selectedTagOptionIds.contains(id) {
            store.selectedTagOptionIds.remove(id)
        } else {
            store.selectedTagOptionIds.insert(id)
        }
    }

    private func toggleStatusOption(_ id: UUID) {
        if store.selectedStatusOptionIds.contains(id) {
            store.selectedStatusOptionIds.remove(id)
        } else {
            store.selectedStatusOptionIds.insert(id)
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
