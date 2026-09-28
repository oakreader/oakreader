import Foundation

@Observable
final class LibraryStore {
    let database: CatalogDatabase

    // Search & filter state
    var searchText: String = ""
    var currentSort: LibrarySortOrder = .dateAdded
    var sortAscending: Bool = false
    var selectedCollectionId: UUID? = SystemCollectionID.readingList
    var selectedTagOptionId: UUID?

    // Middle-pane presentation (Finder-style list vs. masonry card grid), persisted.
    // The card grid's column count is responsive (derived from the pane width in
    // `LibraryCardGridView`), so there is no stored/user-set column count.
    var viewMode: LibraryViewMode = Preferences.shared.libraryViewMode {
        didSet { Preferences.shared.libraryViewMode = viewMode }
    }

    /// Lightweight signal that the background sweep wrote new cover files to disk. Card views
    /// observe this to re-read their cover — it does NOT refetch items (unlike `invalidate()`),
    /// so backfilling covers never triggers a full library reload.
    private(set) var coverRevision: Int = 0
    func bumpCoverRevision() { coverRevision &+= 1 }

    // Toolbar filter state
    var selectedTypes: Set<String> = []
    var selectedTagOptionIds: Set<UUID> = []
    var selectedStatusOptionIds: Set<UUID> = []

    var hasActiveFilters: Bool {
        !selectedTypes.isEmpty || !selectedTagOptionIds.isEmpty || !selectedStatusOptionIds.isEmpty
    }

    func clearFilters() {
        selectedTypes = []
        selectedTagOptionIds = []
        selectedStatusOptionIds = []
    }

    /// Resolved collection for the current selection.
    var selectedCollection: PDFCollection? {
        guard let id = selectedCollectionId else { return nil }
        return collections.first(where: { $0.id == id })
    }

    /// Select a collection and clear tag selection.
    func selectCollection(_ id: UUID?) {
        selectedCollectionId = id
        selectedTagOptionId = nil
    }

    /// Select a tag and clear collection selection.
    func selectTag(_ optionId: UUID?) {
        selectedTagOptionId = optionId
        selectedCollectionId = nil
    }

    /// The system "Tags" property definition.
    var tagsProperty: PropertyDefinition? {
        properties.first { $0.name == "Tags" && $0.isSystem }
    }

    /// Tag options with how many items carry each, most used first.
    ///
    /// Counted over `items` rather than by querying the catalog: that array is
    /// already the live, untrashed library the sidebar is describing, so the
    /// count and the list it labels can never disagree.
    func tagOptionsWithCounts() -> [(option: PropertyOption, count: Int)] {
        guard let tagsProp = tagsProperty else { return [] }

        var counts: [UUID: Int] = [:]
        for item in items {
            for value in item.propertyValues where value.propertyId == tagsProp.id {
                guard let optionId = value.option?.id else { continue }
                counts[optionId, default: 0] += 1
            }
        }

        return tagsProp.options
            .map { (option: $0, count: counts[$0.id] ?? 0) }
            .sorted { $0.count > $1.count }
    }

    /// Which system smart collections are hidden in the sidebar (synced to Preferences).
    var hiddenSystemCollectionIds: Set<UUID> = Preferences.shared.hiddenSystemCollectionIds {
        didSet { Preferences.shared.hiddenSystemCollectionIds = hiddenSystemCollectionIds }
    }

    // Observation trigger — bump this to force computed properties to re-evaluate
    private(set) var revision: Int = 0

    /// The library, held in memory.
    ///
    /// Observed rather than `@ObservationIgnored`: the catalog lives in the
    /// sidecar now, so filling these is a round trip and cannot happen inside a
    /// getter. Views read the array synchronously — a SwiftUI body cannot await
    /// — and a refresh replaces it, which is what drives the redraw.
    private(set) var loadedItems: [LibraryItem] = []
    private(set) var loadedTrashedItems: [LibraryItem] = []
    private(set) var loadedCollections: [PDFCollection] = []
    private(set) var loadedProperties: [PropertyDefinition] = []

    /// Derived from the loaded items, so still worth memoising per revision.
    @ObservationIgnored var duplicateGroupsCache: (revision: Int, groups: [[LibraryItem]])?

    /// True until the first load finishes, so a view can tell "empty library"
    /// from "not read yet" — a distinction that did not exist when the fetch
    /// was synchronous.
    private(set) var isLoading: Bool = true

    /// Coalesces refreshes: several mutations in a row should cost one reload.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Notify the store that data has changed.
    ///
    /// Still synchronous, deliberately: 29 call sites invalidate after a
    /// mutation, and making them all await would spread `async` across the
    /// entire library UI for no benefit. The reload happens behind this.
    func invalidate() {
        duplicateGroupsCache = nil
        revision += 1
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    /// Read the library from the core. Safe to call repeatedly.
    @MainActor
    func refresh() async {
        async let items = LibraryCatalog.items()
        async let trashed = LibraryCatalog.trashedItems()
        async let collections = LibraryCatalog.collections()
        async let properties = PropertyCatalog.list()

        let (i, t, c, p) = await (items, trashed, collections, properties)
        guard !Task.isCancelled else { return }

        let flat = c.map(PDFCollection.init(wire:))
        // Collection ids are resolved here rather than on the wire: sending
        // whole collections per item would repeat 142 of them across 644 items.
        let byId = Dictionary(uniqueKeysWithValues: flat.map { ($0.id, $0) })
        loadedItems = i.map { LibraryItem(wire: $0).resolvingCollections($0.collectionIds, from: byId) }
        loadedTrashedItems = t.map { LibraryItem(wire: $0).resolvingCollections($0.collectionIds, from: byId) }
        loadedCollections = Self.assembleCollectionTree(flat, itemCounts: Self.itemCounts(in: i))
        loadedProperties = p.map(PropertyDefinition.init(wire:))
        duplicateGroupsCache = nil
        isLoading = false

        // Worth a line: an empty library and a failed read look identical on
        // screen, and the difference was invisible in the log the day a
        // megabyte response stopped reassembling.
        Log.info(Log.store, "library loaded: \(loadedItems.count) items, "
            + "\(loadedCollections.count) collections, \(loadedProperties.count) properties, "
            + "\(loadedTrashedItems.count) in the bin")
    }

    /// Count each collection's members from the items just read.
    ///
    /// The wire has no per-collection count — an item carries its collection
    /// ids, not the other way round — so the tally is assembled here. It used
    /// to be `SELECT collection_id, COUNT(*) FROM collection_items GROUP BY …`,
    /// which counted membership rows and so included items sitting in the bin;
    /// counting the live items instead means trashing one now decrements the
    /// sidebar, which is what the number claims to mean.
    private static func itemCounts(in items: [CatalogItem]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for item in items {
            for raw in item.collectionIds {
                guard let id = UUID(uuidString: raw) else { continue }
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    /// Rebuild the parent/child tree, and fill in each collection's item count.
    ///
    /// `catalog/collections/list` returns a FLAT array — every row carries its
    /// `parentId` and nothing else — so `PDFCollection.subcollections` and
    /// `itemCount` keep their empty defaults unless something assembles them.
    /// `fetchAllCollections` used to, reading the tree straight out of GRDB;
    /// it was deleted with the rest of the catalog and nothing replaced it, so
    /// the sidebar drew only the top level and every count read zero.
    ///
    /// Every collection is returned, each carrying its own subtree — the same
    /// shape the GRDB version produced, and what `rootCollections` and the
    /// `CollectionRowView` recursion both expect.
    private static func assembleCollectionTree(
        _ flat: [PDFCollection],
        itemCounts: [UUID: Int]
    ) -> [PDFCollection] {
        var childrenByParent: [UUID: [PDFCollection]] = [:]
        for collection in flat {
            guard let parent = collection.parentId else { continue }
            childrenByParent[parent, default: []].append(collection)
        }

        // `seen` guards a parent cycle. Nothing in the schema forbids one —
        // `parent_id` is a plain self-reference — and a cycle here would
        // recurse until the stack gave out rather than draw a wrong tree.
        func build(_ collection: PDFCollection, seen: Set<UUID>) -> PDFCollection {
            var built = collection
            built.itemCount = itemCounts[collection.id] ?? 0
            guard !seen.contains(collection.id) else {
                built.subcollections = []
                return built
            }
            let seen = seen.union([collection.id])
            built.subcollections = (childrenByParent[collection.id] ?? [])
                .map { build($0, seen: seen) }
            return built
        }

        return flat.map { build($0, seen: []) }
    }

    init(database: CatalogDatabase) {
        self.database = database
    }

    // MARK: - Library Items

    /// The live library. Synchronous by necessity — view bodies read it — and
    /// filled by `refresh()`. Empty before the first load completes; check
    /// `isLoading` to tell that from a genuinely empty library.
    var items: [LibraryItem] { loadedItems }

    // MARK: - Duplicate Detection

    var isDuplicatesSelected: Bool {
        selectedCollectionId == SystemCollectionID.duplicates
    }

    var duplicateGroups: [[LibraryItem]] {
        _ = revision
        if let cached = duplicateGroupsCache, cached.revision == revision {
            return cached.groups
        }
        let groups = DuplicateService.findDuplicates(in: items)
        duplicateGroupsCache = (revision: revision, groups: groups)
        return groups
    }

    /// Map from item ID to its duplicate group index (for visual grouping in the table).
    var duplicateGroupIndexMap: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, group) in duplicateGroups.enumerated() {
            for item in group {
                map[item.id] = index
            }
        }
        return map
    }

    var isReadingListSelected: Bool {
        selectedCollectionId == SystemCollectionID.readingList
    }

    var isRecentlyReadSelected: Bool {
        selectedCollectionId == SystemCollectionID.recentlyRead
    }

    var isBinSelected: Bool {
        selectedCollectionId == SystemCollectionID.bin
    }

    var filteredItems: [LibraryItem] {
        // Special handling for Reading List collection (items not in any user collection)
        if isReadingListSelected {
            return readingListFilteredItems
        }

        // Special handling for Bin collection (trashed items)
        if isBinSelected {
            return binFilteredItems
        }

        // Special handling for Duplicates collection
        if isDuplicatesSelected {
            return duplicatesFilteredItems
        }

        var results = items

        // Apply tag filter (mutually exclusive with collection)
        if let tagId = selectedTagOptionId {
            results = results.filter { item in
                item.propertyValues.contains { $0.option?.id == tagId }
            }
        }
        // Apply collection filter (smart or traditional)
        else if let collection = selectedCollection {
            if collection.isSmart, let rules = collection.filterRules {
                results = results.filter { evaluateRules(rules, against: $0) }
            } else if !collection.isSmart {
                results = results.filter { $0.collections.contains(where: { $0.id == collection.id }) }
            }
            // isSmart with nil rules → show all (e.g. "All Items")
        }

        // Apply toolbar filters (OR within category, AND between categories)
        applyToolbarFilters(to: &results)

        // Apply search & sort
        applySearch(to: &results)
        applySort(to: &results)

        return results
    }

    /// Applies the toolbar Type/Tags/Status filters (OR within a category, AND
    /// between categories). Shared by `filteredItems` and the special pseudo-
    /// collections (Reading List, Duplicates, Bin) so the filter menu works there too.
    private func applyToolbarFilters(to results: inout [LibraryItem]) {
        guard hasActiveFilters else { return }
        results = results.filter { item in
            // Type filter: item matches any selected type (OR)
            if !selectedTypes.isEmpty {
                guard selectedTypes.contains(item.contentType.rawValue) else { return false }
            }
            // Tag filter: item has any selected tag option (OR)
            if !selectedTagOptionIds.isEmpty {
                let itemTagIds = Set(item.propertyValues.compactMap { $0.option?.id })
                guard !itemTagIds.isDisjoint(with: selectedTagOptionIds) else { return false }
            }
            // Status filter: item has any selected status option (OR)
            if !selectedStatusOptionIds.isEmpty {
                let itemStatusIds = Set(item.propertyValues.compactMap { $0.option?.id })
                guard !itemStatusIds.isDisjoint(with: selectedStatusOptionIds) else { return false }
            }
            return true
        }
    }

    // MARK: - Rule Evaluation

    private func evaluateRules(_ rules: FilterRuleSet, against item: LibraryItem) -> Bool {
        if rules.conditions.isEmpty { return true }

        switch rules.match {
        case .all:
            return rules.conditions.allSatisfy { evaluateCondition($0, against: item) }
        case .any:
            return rules.conditions.contains { evaluateCondition($0, against: item) }
        }
    }

    private func evaluateCondition(_ condition: FilterCondition, against item: LibraryItem) -> Bool {
        switch condition.field {
        case .contentType:
            // Match if any attachment has the specified type
            let hasType = item.attachments.contains { $0.contentType.rawValue == condition.value }
            switch condition.op {
            case .eq: return hasType
            case .neq: return !hasType
            default: return matchString(item.contentType.rawValue, op: condition.op, value: condition.value)
            }
        case .lastOpenedAt:
            guard let date = item.lastOpenedAt else { return false }
            return matchDate(date, op: condition.op, value: condition.value)
        case .createdAt:
            return matchDate(item.dateAdded, op: condition.op, value: condition.value)
        case .title:
            return matchString(item.title, op: condition.op, value: condition.value)
        case .author:
            return matchString(item.author, op: condition.op, value: condition.value)
        case .property:
            return matchProperty(item, condition: condition)
        case .source:
            let actual = item.source ?? ""
            return matchString(actual, op: condition.op, value: condition.value)
        }
    }

    private func matchString(_ actual: String, op: FilterOperator, value: String) -> Bool {
        switch op {
        case .eq: return actual.caseInsensitiveCompare(value) == .orderedSame
        case .neq: return actual.caseInsensitiveCompare(value) != .orderedSame
        case .contains: return actual.localizedCaseInsensitiveContains(value)
        default: return false
        }
    }

    private func matchDate(_ actual: Date, op: FilterOperator, value: String) -> Bool {
        switch op {
        case .withinDays:
            guard let days = Int(value) else { return false }
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            return actual >= cutoff
        default:
            return false
        }
    }

    private func matchProperty(_ item: LibraryItem, condition: FilterCondition) -> Bool {
        guard let propertyId = condition.propertyId else { return false }
        let values = item.propertyValues.filter { $0.propertyId.uuidString == propertyId }

        switch condition.op {
        case .hasOption:
            return values.contains { $0.option?.name.caseInsensitiveCompare(condition.value) == .orderedSame }
        case .eq:
            return values.contains { ($0.textValue ?? $0.option?.name ?? "").caseInsensitiveCompare(condition.value) == .orderedSame }
        case .contains:
            return values.contains { ($0.textValue ?? $0.option?.name ?? "").localizedCaseInsensitiveContains(condition.value) }
        default:
            return false
        }
    }

    /// Count items matching a smart collection's rules.
    func smartCollectionItemCount(for collection: PDFCollection) -> Int {
        if collection.id == SystemCollectionID.readingList {
            return readingListItemIds.count
        }
        if collection.id == SystemCollectionID.duplicates {
            return duplicateGroups.flatMap { $0 }.count
        }
        if collection.id == SystemCollectionID.bin {
            return trashedItems.count
        }
        guard collection.isSmart, let rules = collection.filterRules else {
            return collection.itemCount
        }
        return items.filter { evaluateRules(rules, against: $0) }.count
    }

    // MARK: - Search & Sort Helpers

    /// Apply keyword search filtering (title / author / filename) to the given items.
    private func applySearch(to items: inout [LibraryItem]) {
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            items = items.filter {
                $0.title.lowercased().contains(query) ||
                $0.author.lowercased().contains(query) ||
                $0.fileName.lowercased().contains(query)
            }
        }
    }

    /// Apply the current sort order.
    private func applySort(to items: inout [LibraryItem]) {
        // The Recently Read collection always orders by last-opened time (most recent first),
        // matching its "Last Opened" column — regardless of the global sort default.
        let effectiveSort: LibrarySortOrder = isRecentlyReadSelected ? .dateOpened : currentSort
        let effectiveAscending = isRecentlyReadSelected ? false : sortAscending
        items.sort { a, b in
            let cmp: Bool
            switch effectiveSort {
            case .dateAdded:  cmp = a.dateAdded < b.dateAdded
            case .dateOpened: cmp = (a.lastOpenedAt ?? .distantPast) < (b.lastOpenedAt ?? .distantPast)
            case .title:      cmp = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .author:     cmp = a.author.localizedCaseInsensitiveCompare(b.author) == .orderedAscending
            case .fileSize:   cmp = a.fileSize < b.fileSize
            }
            return effectiveAscending ? cmp : !cmp
        }
    }

    // MARK: - Reading List Filtered Items

    /// Set of item IDs that are not in any user (non-system) collection.
    private var readingListItemIds: Set<UUID> {
        Set(items.filter { $0.collections.filter { !$0.isSystem }.isEmpty }.map(\.id))
    }

    /// Items not assigned to any user collection, filtered by search.
    private var readingListFilteredItems: [LibraryItem] {
        let ids = readingListItemIds
        var results = items.filter { ids.contains($0.id) }
        applyToolbarFilters(to: &results)
        applySearch(to: &results)
        applySort(to: &results)
        return results
    }

    // MARK: - Duplicates Filtered Items

    /// Returns all items in duplicate groups, sorted so duplicates within a group appear adjacent.
    private var duplicatesFilteredItems: [LibraryItem] {
        let groups = duplicateGroups
        var results: [LibraryItem] = []
        for group in groups.sorted(by: { DuplicateService.normalizeTitle($0.first?.title ?? "") < DuplicateService.normalizeTitle($1.first?.title ?? "") }) {
            let sorted = group.sorted { a, b in
                a.dateAdded < b.dateAdded
            }
            results.append(contentsOf: sorted)
        }
        applyToolbarFilters(to: &results)
        applySearch(to: &results)
        return results
    }

    // MARK: - Bin (Trashed Items)

    var trashedItems: [LibraryItem] { loadedTrashedItems }

    /// Trashed items filtered by search text.
    private var binFilteredItems: [LibraryItem] {
        var results = trashedItems
        applyToolbarFilters(to: &results)
        applySearch(to: &results)

        // Sort by deleted_at descending (most recently trashed first)
        results.sort { a, b in
            (a.deletedAt ?? .distantPast) > (b.deletedAt ?? .distantPast)
        }

        return results
    }

}
