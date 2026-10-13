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
                    Image(systemName: "magnifyingglass")
                        .font(OakStyle.Font.styledCaption)
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .accessibilityHidden(true)
                    TextField("Search Library", text: $searchText)
                        .font(.system(size: 14))
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

                // Filter, sort and add share one glyph spec with the view-mode
                // pills beside them — see `ToolbarIconLabel`.
                ToolbarIconMenu(
                    systemImage: "line.3.horizontal.decrease",
                    tint: store.hasActiveFilters ? Color.accentColor : nil
                ) {
                    filterMenuContent
                }
                .help("Filter Library")
                .accessibilityLabel("Filter Library")

                ToolbarIconMenu(systemImage: "arrow.up.arrow.down") {
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
                }
                .help("Sort Library")
                .accessibilityLabel("Sort Library")

                // Add sources button — opens the native file picker directly
                Button {
                    chooseFiles()
                } label: {
                    ToolbarIconLabel(systemImage: "plus")
                }
                .buttonStyle(.plain)
                .help("Add files to Library")
                .accessibilityLabel("Add files to Library")
            }
            .padding(.horizontal, 8)
            .frame(height: 44)

        }
        .background(OakStyle.Surface.card)
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

// MARK: - Toolbar Icons

/// One glyph spec for every icon in this toolbar, taken from `PillTabButton`
/// (14pt medium, secondary label colour) so the view-mode pills and the
/// filter / sort / add buttons read as one row. A hover fills the same
/// capsule the pills use.
private struct ToolbarIconLabel: View {
    let systemImage: String
    var tint: Color? = nil

    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint ?? Color(nsColor: .secondaryLabelColor))
            .frame(width: 34, height: 26)
            .background(Capsule().fill(Color.primary.opacity(isHovering ? 0.07 : 0)))
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(OakStyle.Motion.fast, value: isHovering)
    }
}

/// A `Menu` whose label is a `ToolbarIconLabel`. `.borderlessButton` re-tints
/// the label to near-black and adds a chevron, so the menu is drawn as a
/// plain button with the indicator hidden.
private struct ToolbarIconMenu<Content: View>: View {
    let systemImage: String
    var tint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            ToolbarIconLabel(systemImage: systemImage, tint: tint)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
