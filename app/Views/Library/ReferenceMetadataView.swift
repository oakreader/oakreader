import SwiftUI

/// Reference metadata view — Zotero-style two-column grid.
/// Labels right-aligned on the left, values left-aligned on the right.
/// Dynamically renders fields based on CSLTypeFieldRegistry for the selected item type.
struct ReferenceMetadataView: View {
    let item: LibraryItem
    let store: LibraryStore
    let referenceService: ReferenceService
    /// Called with the new title whenever metadata is saved, so an open tab can
    /// live-update its title. Nil when shown outside a document tab (e.g. library).
    var onTitleChange: ((String) -> Void)?

    @State private var cslType: CSLItemType = .document
    @State private var fieldValues: [String: String] = [:]
    @State private var creatorValues: [String: [CSLName]] = [:]
    @State private var dateString: String = ""
    @State private var accessedString: String = ""
    @State private var citeKeyText: String = ""
    @State private var citeKeyError: String?
    @State private var citeKeyInfo: String?
    @State private var pendingRegenKey: String?
    @State private var showRegenConfirm = false
    @State private var isRegenerating = false
    @State private var extraText: String = ""
    @State private var contextualDateStrings: [String: String] = [:]

    @State private var isLookingUp = false
    @State private var isExtracting = false
    /// Why the first extraction failed, if it did. Nil while it is still
    /// running or once metadata exists.
    @State private var extractError: String?
    /// How the core identified this document, kept so the panel can say so.
    @State private var recognition: RecognizedMetadata?
    /// The outcome of a hand-typed identifier lookup. Shown beside the
    /// provenance line, not under the cite key, which is a different subject.
    @State private var lookupMessage: String?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case field(String)
        case date, accessed
        case contextualDate(String)
        case extra
        case creatorFamily(String, Int)
        case creatorGiven(String, Int)
    }

    private let labelWidth: CGFloat = 90

    var body: some View {
        if item.referenceMetadata != nil {
            editableContent
                .onAppear { loadFromMetadata() }
                .onChange(of: item.id) { _, _ in loadFromMetadata() }
                .alert("Regenerate cite key?", isPresented: $showRegenConfirm, presenting: pendingRegenKey) { newKey in
                    Button("Regenerate") { commitRegenerate(to: newKey) }
                    Button("Cancel", role: .cancel) {}
                } message: { newKey in
                    Text("“\(citeKeyText)” → “\(newKey)”.")
                }
        } else {
            extractingState
                // Keyed on the item: @State survives a switch between two
                // items that both lack metadata, so a failure on one would
                // otherwise greet the next.
                .task(id: item.id) {
                    extractError = nil
                    await autoExtract()
                }
        }
    }

    // MARK: - Auto-Extracting State

    @ViewBuilder
    private var extractingState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 8)
            if let message = extractError {
                // A failed save used to leave the spinner turning with nothing
                // behind it, which reads as "still working" and never stops.
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("Couldn’t read this document’s metadata.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") {
                    Task {
                        extractError = nil
                        await autoExtract()
                    }
                }
                .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.regular)
                Text("Extracting metadata…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    /// Fill in this item's metadata the first time the panel shows it.
    ///
    /// The work is the core's: it reads the file's embedded metadata, the
    /// identifiers printed on the page, and the title its typography implies,
    /// then resolves whichever of those it found. See
    /// `backend/src/metadata/recognize.ts`.
    ///
    /// Whatever comes back is written, including the unresolved case, because
    /// the panel's only way out of the spinner is metadata existing.
    private func autoExtract() async {
        guard !isExtracting else { return }
        isExtracting = true
        defer { isExtracting = false }

        do {
            let found = try await MetadataRecognizer.recognize(
                fileURL: item.contentType == .pdf ? item.fileURL : nil,
                title: item.title.isEmpty ? nil : item.title,
                author: item.author.isEmpty ? nil : item.author)
            try await referenceService.saveMetadata(found.cslItem, forItemId: item.id.uuidString)
            recognition = found
            store.invalidate()
            if let title = found.cslItem.title, !title.isEmpty, found.isResolved {
                onTitleChange?(title)
            }
        } catch {
            Log.error(Log.importer, "Recognising \(item.title) failed: \(error)")
            extractError = error.localizedDescription
        }
    }

    // MARK: - Editable Content (Zotero-style grid)

    @ViewBuilder
    private var editableContent: some View {
        let spec = CSLTypeFieldRegistry.spec(for: cslType)

        VStack(alignment: .leading, spacing: 0) {
            if let lookupMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text(lookupMessage).font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            } else if let recognition {
                // Say where this came from. An item the core could not
                // identify looks exactly like one it did unless the panel
                // admits the difference, and a quiet guess is how a wrong
                // citation ends up in a bibliography.
                HStack(spacing: 6) {
                    Image(systemName: recognition.isResolved
                        ? "checkmark.seal" : "questionmark.circle")
                        .font(.system(size: 11))
                    Text(recognition.isResolved
                        ? recognition.summary
                        : "Not identified. \(recognition.summary) Add a DOI or ISBN to look it up.")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }

            // Item Type
            gridRow("Item Type") {
                Picker("", selection: $cslType) {
                    ForEach(CSLItemType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: cslType) { _, _ in saveDebounced() }
            }

            // Cite Key — derived from metadata (Better BibTeX schema), not hand-editable.
            // The only way to change it is Regenerate, which also fixes up existing
            // citations in chat history so links never break silently.
            gridRow("Cite Key") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(citeKeyText.isEmpty ? "—" : citeKeyText)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(citeKeyText.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: prepareRegenerate) {
                            if isRegenerating {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isRegenerating)
                        .help("Regenerate from the current title, author & year")
                    }
                    if let error = citeKeyError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    } else if let info = citeKeyInfo {
                        Text(info)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Dynamic fields from type spec (excluding special-cased ones)
            ForEach(spec.fields, id: \.self) { fieldSpec in
                if fieldSpec.key == "DOI" {
                    doiRow(label: fieldSpec.label)
                } else if fieldSpec.key == "ISBN" {
                    identifierRow(fieldSpec)
                } else if fieldSpec.key == "URL" {
                    urlRow(label: fieldSpec.label)
                } else if fieldSpec.isMultiline {
                    multilineRow(fieldSpec)
                } else {
                    dynamicTextRow(fieldSpec)
                }
            }

            // Date (issued)
            textRowBinding("Date", text: Binding(
                get: { dateString },
                set: { dateString = $0 }
            ), field: .date)

            // Accessed date (only for certain types)
            if cslType == .webpage || cslType == .postWeblog || cslType == .post {
                textRowBinding("Accessed", text: Binding(
                    get: { accessedString },
                    set: { accessedString = $0 }
                ), field: .accessed)
            }

            // Contextual date fields from type spec
            ForEach(spec.dates, id: \.self) { dateSpec in
                textRowBinding(dateSpec.label, text: Binding(
                    get: { contextualDateStrings[dateSpec.key] ?? "" },
                    set: { contextualDateStrings[dateSpec.key] = $0 }
                ), field: .contextualDate(dateSpec.key))
            }

            // Dynamic creator sections from type spec
            ForEach(spec.creators, id: \.self) { creatorSpec in
                creatorSection(spec: creatorSpec)
            }

            // Extra field (monospaced, multiline)
            gridRow("Extra") {
                underlinedField {
                    TextField("", text: $extraText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(2...8)
                        .focused($focusedField, equals: .extra)
                        .onSubmit { saveDebounced() }
                        .onChange(of: focusedField) { old, new in
                            if old == .extra && new != .extra { saveExtra() }
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
                        Image(systemName: "square.on.square")
                            .font(.system(size: 12))
                            .accessibilityHidden(true)
                        Text("Copy Citation")
                            .font(.system(size: 13))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 4)
        }
        .font(.system(size: 14))
    }

    // MARK: - Dynamic Field Rows

    private func dynamicTextRow(_ spec: CSLFieldSpec) -> some View {
        gridRow(spec.label) {
            underlinedField {
                TextField("", text: Binding(
                    get: { fieldValues[spec.key] ?? "" },
                    set: { fieldValues[spec.key] = $0 }
                ))
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .field(spec.key))
                .onSubmit { saveDebounced() }
                .onChange(of: focusedField) { old, new in
                    if old == .field(spec.key) && new != .field(spec.key) { saveDebounced() }
                }
            }
        }
    }

    private func multilineRow(_ spec: CSLFieldSpec) -> some View {
        gridRow(spec.label) {
            underlinedField {
                TextField("", text: Binding(
                    get: { fieldValues[spec.key] ?? "" },
                    set: { fieldValues[spec.key] = $0 }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focusedField, equals: .field(spec.key))
                .onSubmit { saveDebounced() }
                .onChange(of: focusedField) { old, new in
                    if old == .field(spec.key) && new != .field(spec.key) { saveDebounced() }
                }
            }
        }
    }

    /// Resolve whatever identifier sits in this row.
    ///
    /// One button for four registries. The core decides which from the shape
    /// of the string, so a DOI, an arXiv id, an ISBN and a PMID all work where
    /// this used to call CrossRef and only CrossRef.
    @ViewBuilder
    private func lookupButton(for value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespaces).isEmpty {
            Button {
                lookUp(identifier: value)
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
            .help("Fetch this document's details from the identifier")
        }
    }

    /// A text row that can also be resolved.
    private func identifierRow(_ spec: CSLFieldSpec) -> some View {
        gridRow(spec.label) {
            HStack(spacing: 4) {
                underlinedField {
                    TextField("", text: Binding(
                        get: { fieldValues[spec.key] ?? "" },
                        set: { fieldValues[spec.key] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .field(spec.key))
                    .onSubmit { saveDebounced() }
                    .onChange(of: focusedField) { old, new in
                        if old == .field(spec.key) && new != .field(spec.key) { saveDebounced() }
                    }
                }
                lookupButton(for: fieldValues[spec.key] ?? "")
            }
        }
    }

    private func doiRow(label: String) -> some View {
        gridRow(label) {
            HStack(spacing: 4) {
                underlinedField {
                    TextField("", text: Binding(
                        get: { fieldValues["DOI"] ?? "" },
                        set: { fieldValues["DOI"] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .foregroundStyle((fieldValues["DOI"] ?? "").isEmpty ? .primary : Color.accentColor)
                    .focused($focusedField, equals: .field("DOI"))
                    .onSubmit { saveDebounced() }
                    .onChange(of: focusedField) { old, new in
                        if old == .field("DOI") && new != .field("DOI") { saveDebounced() }
                    }
                }
                lookupButton(for: fieldValues["DOI"] ?? "")
            }
        }
    }

    private func urlRow(label: String) -> some View {
        gridRow(label) {
            underlinedField {
                TextField("", text: Binding(
                    get: { fieldValues["URL"] ?? "" },
                    set: { fieldValues["URL"] = $0 }
                ))
                .textFieldStyle(.plain)
                .foregroundStyle((fieldValues["URL"] ?? "").isEmpty ? .primary : Color.accentColor)
                .focused($focusedField, equals: .field("URL"))
                .onSubmit { saveDebounced() }
                .onChange(of: focusedField) { old, new in
                    if old == .field("URL") && new != .field("URL") { saveDebounced() }
                }
            }
        }
    }

    // MARK: - Creator Sections

    @ViewBuilder
    private func creatorSection(spec creatorSpec: CSLCreatorSpec) -> some View {
        let names = creatorValues[creatorSpec.role] ?? []

        if names.isEmpty {
            // Empty row with add button
            gridRow(creatorSpec.label) {
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
                        creatorValues[creatorSpec.role] = [CSLName(family: "", given: "")]
                    }
                }
            }
        } else {
            ForEach(names.indices, id: \.self) { i in
                creatorGridRow(
                    label: i == 0 ? creatorSpec.label : "",
                    role: creatorSpec.role,
                    index: i,
                    isLast: i == names.count - 1
                )
            }
        }
    }

    @ViewBuilder
    private func creatorGridRow(label: String, role: String, index: Int, isLast: Bool) -> some View {
        gridRow(label) {
            HStack(spacing: 4) {
                underlinedField {
                    TextField("(last)", text: Binding(
                        get: { creatorValues[role]?[safe: index]?.family ?? "" },
                        set: { creatorValues[role]?[index].family = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .creatorFamily(role, index))
                    .onSubmit { saveDebounced() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(",")
                    .foregroundStyle(.tertiary)

                underlinedField {
                    TextField("(first)", text: Binding(
                        get: { creatorValues[role]?[safe: index]?.given ?? "" },
                        set: { creatorValues[role]?[index].given = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .creatorGiven(role, index))
                    .onSubmit { saveDebounced() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                circleButton("minus") {
                    creatorValues[role]?.remove(at: index)
                    if creatorValues[role]?.isEmpty == true {
                        creatorValues[role] = nil
                    }
                    saveDebounced()
                }

                if isLast {
                    circleButton("plus") {
                        creatorValues[role, default: []].append(CSLName(family: "", given: ""))
                    }
                }
            }
        }
    }

    // MARK: - Grid Row Components

    @ViewBuilder
    private func gridRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .lineLimit(1)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private func textRowBinding(
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

    @ViewBuilder
    private func underlinedField<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
            }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Data

    private func loadFromMetadata() {
        guard let meta = item.referenceMetadata else { return }
        citeKeyText = item.citeKey ?? ""
        citeKeyError = nil
        citeKeyInfo = nil
        let csl = meta.cslItem

        // Set type
        cslType = CSLItemType(rawValue: csl.type) ?? .document

        // Load all string fields into dictionary
        let spec = CSLTypeFieldRegistry.spec(for: cslType)
        fieldValues = [:]
        for fieldSpec in spec.fields {
            if let val = csl.getField(fieldSpec.key), !val.isEmpty {
                fieldValues[fieldSpec.key] = val
            }
        }

        // Date
        dateString = csl.issued?.year.map { "\($0)" } ?? ""
        accessedString = csl.accessed?.year.map { "\($0)" } ?? ""

        // Contextual dates
        contextualDateStrings = [:]
        if let year = csl.eventDate?.year { contextualDateStrings["eventDate"] = "\(year)" }
        if let year = csl.submitted?.year { contextualDateStrings["submitted"] = "\(year)" }
        if let year = csl.originalDate?.year { contextualDateStrings["originalDate"] = "\(year)" }

        // Extra
        extraText = item.extra ?? ""

        // Load all creator arrays
        creatorValues = [:]
        for creatorSpec in spec.creators {
            if let names = csl.getCreators(role: creatorSpec.role), !names.isEmpty {
                creatorValues[creatorSpec.role] = names
            }
        }
    }

    private func buildCSLItem() -> CSLItem {
        // Start from the existing record so fields not surfaced for the current
        // type (e.g. DOI/volume on a `document`) and sub-year date precision are
        // preserved instead of being wiped on every save.
        var csl = item.referenceMetadata?.cslItem ?? CSLItem(type: cslType.rawValue)
        csl.type = cslType.rawValue

        let spec = CSLTypeFieldRegistry.spec(for: cslType)

        // Overwrite only the fields shown for this type (empty → cleared).
        for fieldSpec in spec.fields {
            let trimmed = (fieldValues[fieldSpec.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            csl.setField(fieldSpec.key, value: trimmed.isEmpty ? nil : trimmed)
        }

        // Dates — preserve month/day when the displayed year is unchanged.
        csl.issued = mergeYear(dateString, into: csl.issued)
        csl.accessed = mergeYear(accessedString, into: csl.accessed)
        csl.eventDate = mergeYear(contextualDateStrings["eventDate"], into: csl.eventDate)
        csl.submitted = mergeYear(contextualDateStrings["submitted"], into: csl.submitted)
        csl.originalDate = mergeYear(contextualDateStrings["originalDate"], into: csl.originalDate)

        // Overwrite only the creator roles shown for this type.
        for creatorSpec in spec.creators {
            let names = (creatorValues[creatorSpec.role] ?? [])
                .filter { !($0.family ?? "").isEmpty || !($0.given ?? "").isEmpty }
            csl.setCreators(role: creatorSpec.role, names: names.isEmpty ? nil : names)
        }

        return csl
    }

    /// Apply an edited year string to a date while keeping the existing
    /// month/day when the year hasn't changed. Empty clears the date; a
    /// non-numeric value leaves the existing date untouched.
    private func mergeYear(_ str: String?, into existing: CSLDate?) -> CSLDate? {
        let trimmed = (str ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let year = Int(trimmed) else { return existing }
        if existing?.year == year { return existing }
        return CSLDate(year: year)
    }

    private func saveDebounced() {
        let csl = buildCSLItem()
        Task { @MainActor in
            do {
                try await referenceService.saveMetadata(csl, forItemId: item.id.uuidString)
                store.invalidate()
                if let title = csl.title, !title.isEmpty {
                    onTitleChange?(title)
                }
            } catch {
                Log.error(Log.store, "Failed to save reference metadata: \(error)")
            }
        }
    }

    private func saveExtra() {
        let trimmed = extraText.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemId = item.id.uuidString
        Task { @MainActor in
            await LibraryCatalog.update(
                id: itemId, field: "extra", string: trimmed.isEmpty ? nil : trimmed)
            store.invalidate()
        }
    }

    /// Offer the cite key the item's current metadata would produce.
    ///
    /// The proposal comes from the core, which computes it and checks it
    /// against every other key in one pass — the panel only asks, and shows a
    /// confirmation before anything is renamed.
    private func prepareRegenerate() {
        guard !isRegenerating else { return }
        citeKeyError = nil
        citeKeyInfo = nil
        isRegenerating = true
        let itemId = item.id.uuidString
        let current = citeKeyText.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            let proposed = await ReferenceCatalog.proposedCiteKey(forItemId: itemId)
            isRegenerating = false
            guard let proposed, !proposed.isEmpty else {
                citeKeyInfo = "Not enough metadata to generate a cite key."
                return
            }
            guard proposed != current else {
                citeKeyInfo = "Already up to date."
                return
            }
            pendingRegenKey = proposed
            showRegenConfirm = true
        }
    }

    /// Commit the rename, surfacing a clash rather than silently picking
    /// another key.
    ///
    /// Renaming a cite key used to have to rewrite every `oak://cite/{key}` link in every
    /// stored transcript, because the key was baked into the citation URL. Citations now
    /// carry a passage number that resolves through the conversation's source table to a
    /// stable item id, so a rename is invisible to them and nothing needs rewriting.
    private func commitRegenerate(to newKey: String) {
        guard !isRegenerating else { return }
        let itemId = item.id.uuidString
        isRegenerating = true
        Task { @MainActor in
            defer { isRegenerating = false }
            do {
                try await ReferenceCatalog.saveCiteKey(newKey, forItemId: itemId)
            } catch {
                citeKeyError = error.localizedDescription
                return
            }
            citeKeyText = newKey
            citeKeyError = nil
            citeKeyInfo = nil
            store.invalidate()
        }
    }

    private func lookUp(identifier: String) {
        let typed = identifier.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        lookupMessage = nil
        Task {
            defer { isLookingUp = false }
            do {
                let found = try await MetadataRecognizer.recognize(
                    fileURL: nil, identifier: typed)
                guard found.isResolved else {
                    lookupMessage = "No record found for \(typed)."
                    return
                }
                try await referenceService.saveMetadata(
                    found.cslItem, forItemId: item.id.uuidString)
                recognition = found
                store.invalidate()
                if let title = found.cslItem.title, !title.isEmpty { onTitleChange?(title) }
            } catch {
                lookupMessage = error.localizedDescription
                Log.error(Log.store, "Identifier lookup failed for \(typed): \(error)")
            }
        }
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
