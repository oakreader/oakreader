import SwiftUI
import UniformTypeIdentifiers

// Library toolbar: height 41px, 28x28 buttons, 6px radius
struct LibraryTableToolbar: View {
    let appState: AppState

    @State private var searchText = ""

    private var store: LibraryStore { appState.libraryStore }

    private var statusProperty: PropertyDefinition? {
        store.properties.first { $0.name == "Status" && $0.isSystem }
    }

    private let filterableTypes: [(type: ContentType, label: String)] = [
        (.pdf, "PDF"),
        (.html, "Web"),
        (.link, "Bookmark"),
        (.markdown, "Markdown"),
        (.audio, "Audio"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Main toolbar row
            HStack(spacing: 8) {
                // Search field
                HStack(spacing: 6) {
                    if store.ftsIndexService != nil {
                        Button {
                            store.isFullTextSearchActive.toggle()
                            if store.isFullTextSearchActive && !searchText.isEmpty {
                                store.performFullTextSearch()
                            } else if !store.isFullTextSearchActive {
                                store.clearFullTextSearch()
                            }
                        } label: {
                            Image(systemName: store.isFullTextSearchActive
                                  ? "text.magnifyingglass"
                                  : "magnifyingglass")
                                .font(OakStyle.Font.styledCaption)
                                .foregroundStyle(store.isFullTextSearchActive
                                    ? Color.accentColor
                                    : Color.primary.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help(store.isFullTextSearchActive ? "Switch to title search" : "Switch to full-text content search")
                        .accessibilityLabel(store.isFullTextSearchActive ? "Full-text search active" : "Title search active")
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(OakStyle.Font.styledCaption)
                            .foregroundStyle(Color.primary.opacity(0.55))
                            .accessibilityHidden(true)
                    }
                    TextField(
                        store.isFullTextSearchActive ? "Search by meaning..." : "Search Library",
                        text: $searchText
                    )
                        .font(.system(size: 14))
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search library")
                        .onChange(of: searchText) { _, newValue in
                            store.searchText = newValue
                            if store.isFullTextSearchActive {
                                store.performFullTextSearch()
                            }
                        }
                    if store.isFullTextSearching {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
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

                // List / card view-mode toggle — same expanding-pill tabs as the
                // title-bar panel tabs (active mode reveals its label).
                HStack(spacing: 2) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        PillTabButton(
                            systemImage: mode.symbol,
                            label: mode.label,
                            isActive: store.viewMode == mode
                        ) {
                            store.viewMode = mode
                        }
                    }
                }
                .accessibilityLabel("Library view mode")

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

                // Add sources button — opens the native file picker directly
                Button {
                    chooseFiles()
                } label: {
                    Image(systemName: "plus")
                        // Same 0.55 grey as the filter/sort glyphs, but a heavier weight:
                        // the thin + cross has little ink, so at the identical colour it
                        // read fainter than the denser icons beside it. .semibold gives it
                        // the matching visual weight without changing the hue.
                        .font(.system(size: OakStyle.Font.icon, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                }
                // `.plain` (not `.borderless`): the borderless button style tints/emphasises
                // its template glyph, so the + rendered darker than the filter/sort menu
                // glyphs despite the identical foregroundStyle. `.plain` renders the label
                // exactly as specified, matching the 0.55 grey of the icons beside it.
                .buttonStyle(.plain)
                .help("Add files to Library")
                .accessibilityLabel("Add files to Library")
            }
            .padding(.horizontal, 8)
            .frame(height: 44)

        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    /// Opens the native macOS file picker and imports the chosen files (or folders)
    /// straight into the library — same import path as drag-and-drop.
    private func chooseFiles() {
        var contentTypes: [UTType] = [.pdf, .html, .audio, .plainText]
        if let mdType = UTType(filenameExtension: "md") { contentTypes.append(mdType) }
        if let markdownType = UTType(filenameExtension: "markdown") { contentTypes.append(markdownType) }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Select files to add to your library"
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            importPicked(panel.urls)
        }
    }

    private func importPicked(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists, isDir.boolValue {
                Task {
                    let count = await store.importFolder(url, importService: appState.importService)
                    await MainActor.run {
                        withAnimation {
                            appState.importNotification = "Imported \(count) item\(count == 1 ? "" : "s") from \"\(url.lastPathComponent)\""
                        }
                    }
                }
                continue
            }
            Task {
                let item = await appState.importService.importFileAsync(from: url)
                guard let item else { return }
                await MainActor.run {
                    if let collection = store.selectedCollection, !collection.isSmart {
                        store.addItem(item, to: collection)
                    }
                }
            }
        }
    }
}
