import SwiftUI

/// Reference metadata view — Zotero-style two-column grid.
/// Labels right-aligned on the left, values left-aligned on the right.
struct ReferenceMetadataView: View {
    let item: LibraryItem
    let store: LibraryStore
    let referenceService: ReferenceService

    @State private var cslType: String = "document"
    @State private var doi: String = ""
    @State private var title: String = ""
    @State private var containerTitle: String = ""
    @State private var yearString: String = ""
    @State private var volume: String = ""
    @State private var issue: String = ""
    @State private var page: String = ""
    @State private var publisher: String = ""
    @State private var publisherPlace: String = ""
    @State private var isbn: String = ""
    @State private var issn: String = ""
    @State private var url: String = ""
    @State private var abstract: String = ""
    @State private var authors: [CSLName] = []
    @State private var editors: [CSLName] = []

    @State private var isLookingUp = false
    @State private var isExtracting = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case doi, title, containerTitle, year, volume, issue, page
        case publisher, publisherPlace, isbn, issn, url, abstract
        case authorFamily(Int), authorGiven(Int)
    }

    private let labelWidth: CGFloat = 80

    var body: some View {
        if item.referenceMetadata != nil {
            editableContent
                .onAppear { loadFromMetadata() }
                .onChange(of: item.id) { _, _ in loadFromMetadata() }
        } else {
            emptyState
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)
            Image(systemName: "text.quote")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.quaternary)

            VStack(spacing: 4) {
                Text("No Reference Data")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Extract from the PDF or add manually.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                Button {
                    extractFromPDF()
                } label: {
                    HStack(spacing: 5) {
                        if isExtracting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 12))
                        }
                        Text("Extract from PDF")
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isExtracting || item.itemType != .pdf)

                Button {
                    createEmptyMetadata()
                } label: {
                    Text("Add Manually")
                        .font(.system(size: 12))
                        .frame(maxWidth: 180)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Editable Content (Zotero-style grid)

    @ViewBuilder
    private var editableContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Item Type — full width picker
            gridRow("Item Type") {
                Picker("", selection: $cslType) {
                    ForEach(CSLItemType.allCases) { type in
                        Text(type.displayName).tag(type.rawValue)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: cslType) { _, _ in saveDebounced() }
            }

            // Title
            textRow("Title", text: $title, field: .title)

            // Authors
            ForEach(authors.indices, id: \.self) { i in
                authorGridRow(
                    label: i == 0 ? "Author" : "",
                    index: i,
                    isLast: i == authors.count - 1
                )
            }

            // If no authors, show empty row with add button
            if authors.isEmpty {
                gridRow("Author") {
                    HStack(spacing: 4) {
                        Text("(last)")
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(",")
                            .foregroundStyle(.quaternary)
                        Text("(first)")
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        circleButton("plus") {
                            authors.append(CSLName(family: "", given: ""))
                        }
                    }
                }
            }

            // Journal / Container
            textRow("Journal", text: $containerTitle, field: .containerTitle)

            // Date / Year
            textRow("Date", text: $yearString, field: .year)

            // Volume
            textRow("Volume", text: $volume, field: .volume)

            // Issue
            textRow("Issue", text: $issue, field: .issue)

            // Pages
            textRow("Pages", text: $page, field: .page)

            // Publisher
            textRow("Publisher", text: $publisher, field: .publisher)

            // Place
            textRow("Place", text: $publisherPlace, field: .publisherPlace)

            // DOI
            gridRow("DOI") {
                HStack(spacing: 4) {
                    underlinedField {
                        TextField("", text: $doi)
                            .textFieldStyle(.plain)
                            .foregroundStyle(doi.isEmpty ? .primary : Color.accentColor)
                            .focused($focusedField, equals: .doi)
                            .onSubmit { saveDebounced() }
                            .onChange(of: focusedField) { old, new in
                                if old == .doi && new != .doi { saveDebounced() }
                            }
                    }
                    if !doi.isEmpty {
                        Button {
                            lookupDOI()
                        } label: {
                            if isLookingUp {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLookingUp)
                        .help("Refresh metadata from CrossRef")
                    }
                }
            }

            // ISBN
            textRow("ISBN", text: $isbn, field: .isbn)

            // ISSN
            textRow("ISSN", text: $issn, field: .issn)

            // URL
            gridRow("URL") {
                underlinedField {
                    TextField("", text: $url)
                        .textFieldStyle(.plain)
                        .foregroundStyle(url.isEmpty ? .primary : Color.accentColor)
                        .focused($focusedField, equals: .url)
                        .onSubmit { saveDebounced() }
                        .onChange(of: focusedField) { old, new in
                            if old == .url && new != .url { saveDebounced() }
                        }
                }
            }

            // Abstract
            gridRow("Abstract") {
                underlinedField {
                    TextField("", text: $abstract, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($focusedField, equals: .abstract)
                        .onSubmit { saveDebounced() }
                        .onChange(of: focusedField) { old, new in
                            if old == .abstract && new != .abstract { saveDebounced() }
                        }
                }
            }

            Spacer().frame(height: 8)

            // Copy Citation — right-aligned button
            HStack {
                Spacer()
                Menu {
                    Section("Formatted") {
                        ForEach(CitationStyle.allCases.filter(\.isHumanReadable)) { style in
                            Button(style.displayName) { store.copyCitation(item, style: style) }
                        }
                    }
                    Section("Export") {
                        ForEach(CitationStyle.allCases.filter { !$0.isHumanReadable }) { style in
                            Button(style.displayName) { store.copyCitation(item, style: style) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                        Text("Copy Citation")
                            .font(.system(size: 12))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 4)
        }
        .font(.system(size: 13))
    }

    // MARK: - Grid Row Components

    /// Generic grid row: right-aligned label, left-aligned content.
    @ViewBuilder
    private func gridRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .lineLimit(1)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
    }

    /// Text field grid row with underline.
    private func textRow(
        _ label: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        gridRow(label) {
            underlinedField {
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: field)
                    .onSubmit { saveDebounced() }
                    .onChange(of: focusedField) { old, new in
                        if old == field && new != field { saveDebounced() }
                    }
            }
        }
    }

    /// Wraps content with a subtle bottom underline to indicate editability.
    @ViewBuilder
    private func underlinedField<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }
    }

    /// Author row with fixed proportional columns: [last] , [first] [−] [+]
    @ViewBuilder
    private func authorGridRow(label: String, index: Int, isLast: Bool) -> some View {
        gridRow(label) {
            HStack(spacing: 4) {
                underlinedField {
                    TextField("(last)", text: Binding(
                        get: { authors[index].family ?? "" },
                        set: { authors[index].family = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .authorFamily(index))
                    .onSubmit { saveDebounced() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(",")
                    .foregroundStyle(.tertiary)

                underlinedField {
                    TextField("(first)", text: Binding(
                        get: { authors[index].given ?? "" },
                        set: { authors[index].given = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .authorGiven(index))
                    .onSubmit { saveDebounced() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                circleButton("minus") {
                    authors.remove(at: index)
                    saveDebounced()
                }

                if isLast {
                    circleButton("plus") {
                        authors.append(CSLName(family: "", given: ""))
                    }
                }
            }
        }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Data

    private func loadFromMetadata() {
        guard let meta = item.referenceMetadata else { return }
        let csl = meta.cslItem
        cslType = csl.type
        doi = csl.DOI ?? ""
        title = csl.title ?? ""
        containerTitle = csl.containerTitle ?? ""
        yearString = csl.issued?.year.map { "\($0)" } ?? ""
        volume = csl.volume ?? ""
        issue = csl.issue ?? ""
        page = csl.page ?? ""
        publisher = csl.publisher ?? ""
        publisherPlace = csl.publisherPlace ?? ""
        isbn = csl.ISBN ?? ""
        issn = csl.ISSN ?? ""
        url = csl.URL ?? ""
        abstract = csl.abstract ?? ""
        authors = csl.author ?? []
        editors = csl.editor ?? []
    }

    private func buildCSLItem() -> CSLItem {
        var csl = CSLItem(type: cslType)
        csl.title = title.isEmpty ? nil : title
        csl.DOI = doi.isEmpty ? nil : doi
        csl.containerTitle = containerTitle.isEmpty ? nil : containerTitle
        csl.volume = volume.isEmpty ? nil : volume
        csl.issue = issue.isEmpty ? nil : issue
        csl.page = page.isEmpty ? nil : page
        csl.publisher = publisher.isEmpty ? nil : publisher
        csl.publisherPlace = publisherPlace.isEmpty ? nil : publisherPlace
        csl.ISBN = isbn.isEmpty ? nil : isbn
        csl.ISSN = issn.isEmpty ? nil : issn
        csl.URL = url.isEmpty ? nil : url
        csl.abstract = abstract.isEmpty ? nil : abstract
        if let year = Int(yearString) {
            csl.issued = CSLDate(year: year)
        }
        let filteredAuthors = authors.filter { !($0.family ?? "").isEmpty || !($0.given ?? "").isEmpty }
        csl.author = filteredAuthors.isEmpty ? nil : filteredAuthors
        let filteredEditors = editors.filter { !($0.family ?? "").isEmpty || !($0.given ?? "").isEmpty }
        csl.editor = filteredEditors.isEmpty ? nil : filteredEditors
        return csl
    }

    private func saveDebounced() {
        let csl = buildCSLItem()
        do {
            try referenceService.saveMetadata(csl, forItemId: item.id.uuidString)
            store.invalidate()
        } catch {
            Log.error(Log.store, "Failed to save reference metadata: \(error)")
        }
    }

    private func extractFromPDF() {
        isExtracting = true
        Task {
            let pdfURL = item.fileURL
            if let foundDOI = DOIExtractorService.extractDOI(from: pdfURL) {
                doi = foundDOI
                do {
                    let cslItem = try await CrossRefService.fetchMetadata(doi: foundDOI)
                    try referenceService.saveMetadata(cslItem, forItemId: item.id.uuidString)
                    await MainActor.run {
                        store.invalidate()
                        isExtracting = false
                    }
                    return
                } catch {
                    Log.error(Log.importer, "CrossRef lookup failed: \(error)")
                }
            }
            await MainActor.run {
                createEmptyMetadata()
                isExtracting = false
            }
        }
    }

    private func lookupDOI() {
        guard !doi.isEmpty else { return }
        isLookingUp = true
        Task {
            do {
                let cslItem = try await CrossRefService.fetchMetadata(doi: doi)
                try referenceService.saveMetadata(cslItem, forItemId: item.id.uuidString)
                await MainActor.run {
                    store.invalidate()
                    isLookingUp = false
                }
            } catch {
                await MainActor.run { isLookingUp = false }
                Log.error(Log.store, "DOI lookup failed: \(error)")
            }
        }
    }

    private func createEmptyMetadata() {
        var csl = CSLItem(type: "document")
        csl.title = item.title
        if !item.author.isEmpty {
            csl.author = [CSLName(family: item.author, given: nil)]
        }
        do {
            try referenceService.saveMetadata(csl, forItemId: item.id.uuidString)
            store.invalidate()
        } catch {
            Log.error(Log.store, "Failed to create empty reference metadata: \(error)")
        }
    }
}
