import AppKit
import Foundation
import GRDB
import PDFKit

@Observable
final class LibraryStore {
    let database: CatalogDatabase
    var semanticIndexService: SemanticIndexService?

    // Search & filter state
    var searchText: String = ""
    var currentSort: LibrarySortOrder = .dateAdded
    var sortAscending: Bool = false
    var selectedCollectionId: UUID? = SystemCollectionID.allItems
    var selectedTagOptionId: UUID?

    // Semantic search state
    var isSemanticSearchActive: Bool = false
    var semanticSearchResults: [UUID: SemanticIndexService.SearchResult]?
    var semanticSearchOrder: [UUID]?
    var isSemanticSearching: Bool = false
    @ObservationIgnored var semanticSearchTask: Task<Void, Never>?

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

    func clearSemanticSearch() {
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchResults = nil
        semanticSearchOrder = nil
        isSemanticSearching = false
    }

    func performSemanticSearch() {
        semanticSearchTask?.cancel()

        guard isSemanticSearchActive, !searchText.isEmpty,
              let service = semanticIndexService else {
            clearSemanticSearch()
            return
        }

        let query = searchText
        isSemanticSearching = true

        semanticSearchTask = Task { @MainActor in
            // Debounce 300ms
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            let results = await service.search(query: query, maxResults: 50)
            guard !Task.isCancelled else { return }

            var resultsMap: [UUID: SemanticIndexService.SearchResult] = [:]
            var order: [UUID] = []
            for result in results {
                guard let id = UUID(uuidString: result.itemId) else { continue }
                resultsMap[id] = result
                order.append(id)
            }
            semanticSearchResults = resultsMap
            semanticSearchOrder = order
            isSemanticSearching = false
        }
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
        clearSemanticSearch()
    }

    /// Select a tag and clear collection selection.
    func selectTag(_ optionId: UUID?) {
        selectedTagOptionId = optionId
        selectedCollectionId = nil
        clearSemanticSearch()
    }

    /// The system "Tags" property definition.
    var tagsProperty: PropertyDefinition? {
        properties.first { $0.name == "Tags" && $0.isSystem }
    }

    /// Returns tag options with their item counts, sorted by count descending.
    func tagOptionsWithCounts() -> [(option: PropertyOption, count: Int)] {
        guard let tagsProp = tagsProperty else { return [] }
        let allItems = items
        return tagsProp.options.map { option in
            let count = allItems.filter { item in
                item.propertyValues.contains { $0.option?.id == option.id }
            }.count
            return (option: option, count: count)
        }.sorted { $0.count > $1.count }
    }

    /// Which system smart collections are hidden in the sidebar (synced to Preferences).
    var hiddenSystemCollectionIds: Set<UUID> = Preferences.shared.hiddenSystemCollectionIds {
        didSet { Preferences.shared.hiddenSystemCollectionIds = hiddenSystemCollectionIds }
    }

    // Observation trigger — bump this to force computed properties to re-evaluate
    private(set) var revision: Int = 0

    // Caches keyed on revision — avoids redundant DB fetches within the same revision cycle.
    // Marked @ObservationIgnored so writes inside computed getters don't trigger extra observations.
    @ObservationIgnored var itemsCache: (revision: Int, items: [LibraryItem])?
    @ObservationIgnored var collectionsCache: (revision: Int, collections: [PDFCollection])?
    @ObservationIgnored var propertiesCache: (revision: Int, properties: [PropertyDefinition])?
    @ObservationIgnored var duplicateGroupsCache: (revision: Int, groups: [[LibraryItem]])?

    /// Notify the store that data has changed externally.
    func invalidate() {
        itemsCache = nil
        collectionsCache = nil
        propertiesCache = nil
        duplicateGroupsCache = nil
        revision += 1
    }

    init(database: CatalogDatabase) {
        self.database = database
    }

    // MARK: - Library Items

    var items: [LibraryItem] {
        _ = revision
        if let cached = itemsCache, cached.revision == revision {
            return cached.items
        }
        let result = (try? fetchAllItems()) ?? []
        itemsCache = (revision: revision, items: result)
        return result
    }

    func findItem(byCiteKey citeKey: String) -> LibraryItem? {
        items.first { $0.citeKey == citeKey }
    }

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

    var isFlashcardsSelected: Bool {
        selectedCollectionId == SystemCollectionID.flashcards
    }

    var filteredItems: [LibraryItem] {
        // Special handling for Duplicates collection
        if isDuplicatesSelected {
            return duplicatesFilteredItems
        }

        // Special handling for Flashcards collection (items with quiz cards)
        if isFlashcardsSelected {
            return flashcardsFilteredItems
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
        if hasActiveFilters {
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

        // Apply search
        if isSemanticSearchActive && !searchText.isEmpty {
            if let order = semanticSearchOrder, let resultsMap = semanticSearchResults {
                let matchingIds = Set(order)
                results = results.filter { matchingIds.contains($0.id) }
                // Sort by relevance score (highest first)
                results.sort { a, b in
                    let scoreA = resultsMap[a.id]?.score ?? 0
                    let scoreB = resultsMap[b.id]?.score ?? 0
                    return scoreA > scoreB
                }
            }
            // When searching but no results yet, keep current results unfiltered
            return results
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            results = results.filter {
                $0.title.lowercased().contains(query) ||
                $0.author.lowercased().contains(query) ||
                $0.fileName.lowercased().contains(query)
            }
        }

        // Sort (keyword mode only — semantic mode sorted by score above)
        results.sort { a, b in
            let cmp: Bool
            switch currentSort {
            case .dateAdded:  cmp = a.dateAdded < b.dateAdded
            case .dateOpened: cmp = (a.lastOpenedAt ?? .distantPast) < (b.lastOpenedAt ?? .distantPast)
            case .title:      cmp = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .author:     cmp = a.author.localizedCaseInsensitiveCompare(b.author) == .orderedAscending
            case .fileSize:   cmp = a.fileSize < b.fileSize
            }
            return sortAscending ? cmp : !cmp
        }

        return results
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
        if collection.id == SystemCollectionID.duplicates {
            return duplicateGroups.flatMap { $0 }.count
        }
        if collection.id == SystemCollectionID.flashcards {
            return flashcardsItemIds.count
        }
        guard collection.isSmart, let rules = collection.filterRules else {
            return collection.itemCount
        }
        return items.filter { evaluateRules(rules, against: $0) }.count
    }

    // MARK: - Flashcards Filtered Items

    /// Set of item IDs that have at least one quiz card.
    private var flashcardsItemIds: Set<UUID> {
        let ids = (try? database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM quiz_cards WHERE is_suspended = 0")
        }) ?? []
        return Set(ids.compactMap { UUID(uuidString: $0) })
    }

    /// Items that have quiz cards saved.
    private var flashcardsFilteredItems: [LibraryItem] {
        let itemIds = flashcardsItemIds
        return items.filter { itemIds.contains($0.id) }
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

        // Apply search within duplicates
        if isSemanticSearchActive && !searchText.isEmpty {
            if let order = semanticSearchOrder, let resultsMap = semanticSearchResults {
                let matchingIds = Set(order)
                results = results.filter { matchingIds.contains($0.id) }
                results.sort { a, b in
                    let scoreA = resultsMap[a.id]?.score ?? 0
                    let scoreB = resultsMap[b.id]?.score ?? 0
                    return scoreA > scoreB
                }
            }
        } else if !searchText.isEmpty {
            let query = searchText.lowercased()
            results = results.filter {
                $0.title.lowercased().contains(query) ||
                $0.author.lowercased().contains(query) ||
                $0.fileName.lowercased().contains(query)
            }
        }

        return results
    }

}
