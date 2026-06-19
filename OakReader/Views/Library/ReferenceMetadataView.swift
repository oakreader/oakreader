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
    @State private var regenAffectedCount: Int = 0
    @State private var showRegenConfirm = false
    @State private var isRegenerating = false
    @State private var extraText: String = ""
    @State private var contextualDateStrings: [String: String] = [:]

    @State private var isLookingUp = false
    @State private var isExtracting = false

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
                    if regenAffectedCount > 0 {
                        Text("“\(citeKeyText)” → “\(newKey)”.\n\(regenAffectedCount) citation\(regenAffectedCount == 1 ? "" : "s") in your chat history will be updated to the new key.")
                    } else {
                        Text("“\(citeKeyText)” → “\(newKey)”.")
                    }
                }
        } else {
            extractingState
                .onAppear { autoExtract() }
        }
    }

    // MARK: - Auto-Extracting State

    private var extractingState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)
            ProgressView()
                .controlSize(.regular)
            Text("Extracting metadata…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func autoExtract() {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            if item.contentType == .pdf {
                if let foundDOI = DOIExtractorService.extractDOI(from: item.fileURL) {
                    do {
                        let cslItem = try await CrossRefService.fetchMetadata(doi: foundDOI)
                        try referenceService.saveMetadata(cslItem, forItemId: item.id.uuidString)
                        await MainActor.run {
                            store.invalidate()
                            if let title = cslItem.title, !title.isEmpty { onTitleChange?(title) }
                            isExtracting = false
                        }
                        return
                    } catch {
                        Log.error(Log.importer, "CrossRef lookup failed: \(error)")
                    }
                }
            }
            // Fallback: create metadata from document info
            await MainActor.run {
                createEmptyMetadata()
                isExtracting = false
            }
        }
    }

    // MARK: - Editable Content (Zotero-style grid)

    @ViewBuilder
    private var editableContent: some View {
        let spec = CSLTypeFieldRegistry.spec(for: cslType)

        VStack(alignment: .leading, spacing: 0) {
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
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
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
                if !(fieldValues["DOI"] ?? "").isEmpty {
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
        do {
            try referenceService.saveMetadata(csl, forItemId: item.id.uuidString)
            store.invalidate()
            if let title = csl.title, !title.isEmpty {
                onTitleChange?(title)
            }
        } catch {
            Log.error(Log.store, "Failed to save reference metadata: \(error)")
        }
    }

    private func saveExtra() {
        let trimmed = extraText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE items SET extra = ?, updated_at = ? WHERE id = ?",
                    arguments: [trimmed.isEmpty ? nil : trimmed, Date().iso8601String, item.id.uuidString]
                )
            }
            store.invalidate()
        } catch {
            Log.error(Log.store, "Failed to save extra field: \(error)")
        }
    }

    /// Compute the cite key the item *would* get from its current metadata. If it differs
    /// from the stored key, count how many chat citations reference the old key and ask the
    /// user to confirm before committing. The DB read and the chat-history scan run off the
    /// main thread so the panel never hitches on a large library.
    private func prepareRegenerate() {
        guard !isRegenerating else { return }
        citeKeyError = nil
        citeKeyInfo = nil
        isRegenerating = true
        let database = store.database
        let itemId = item.id.uuidString
        let current = citeKeyText.trimmingCharacters(in: .whitespaces)
        Task.detached {
            let service = CiteKeyService(database: database)
            let proposed = (try? service.proposedKey(forItemId: itemId)) ?? nil
            let isChange = proposed != nil && !proposed!.isEmpty && proposed != current
            let count = (isChange && !current.isEmpty) ? CiteLinkRewriter.countReferences(toKey: current) : 0
            await MainActor.run {
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
                regenAffectedCount = count
                showRegenConfirm = true
            }
        }
    }

    /// Write the new key and rewrite matching `oak://cite/` links in chat history, off the
    /// main thread. Surfaces any write failures, and notifies open chat views to reload.
    private func commitRegenerate(to newKey: String) {
        guard !isRegenerating else { return }
        let oldKey = citeKeyText.trimmingCharacters(in: .whitespaces)
        let database = store.database
        let itemId = item.id.uuidString
        isRegenerating = true
        Task.detached {
            var saveError: String?
            var result = CiteLinkRewriter.RewriteResult.empty
            do {
                try CiteKeyService(database: database).saveCiteKey(newKey, forItemId: itemId)
                if !oldKey.isEmpty {
                    result = CiteLinkRewriter.rewrite(from: oldKey, to: newKey)
                }
            } catch {
                saveError = error.localizedDescription
            }
            await MainActor.run {
                isRegenerating = false
                if let saveError {
                    citeKeyError = saveError
                    return
                }
                citeKeyText = newKey
                citeKeyError = nil
                var parts: [String] = []
                if result.linksRewritten > 0 {
                    parts.append("Updated \(result.linksRewritten) citation\(result.linksRewritten == 1 ? "" : "s") in chat history.")
                }
                if result.failedFiles > 0 {
                    parts.append("\(result.failedFiles) chat file\(result.failedFiles == 1 ? "" : "s") could not be updated.")
                }
                citeKeyInfo = parts.isEmpty ? nil : parts.joined(separator: " ")
                store.invalidate()
                if !result.affectedSessions.isEmpty {
                    NotificationCenter.default.post(
                        name: .oakCiteKeysRewritten,
                        object: nil,
                        userInfo: ["sessions": result.affectedSessions]
                    )
                }
            }
        }
    }

    private func lookupDOI() {
        let doi = fieldValues["DOI"] ?? ""
        guard !doi.isEmpty else { return }
        isLookingUp = true
        Task {
            do {
                let cslItem = try await CrossRefService.fetchMetadata(doi: doi)
                try referenceService.saveMetadata(cslItem, forItemId: item.id.uuidString)
                await MainActor.run {
                    store.invalidate()
                    if let title = cslItem.title, !title.isEmpty { onTitleChange?(title) }
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

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
