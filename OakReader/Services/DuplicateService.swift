import Foundation

// MARK: - Disjoint Set Forest (Union-Find)

/// Lightweight Union-Find data structure for grouping items by equivalence.
struct DisjointSetForest<T: Hashable> {
    private var parent: [T: T] = [:]
    private var rank: [T: Int] = [:]

    mutating func makeSet(_ x: T) {
        guard parent[x] == nil else { return }
        parent[x] = x
        rank[x] = 0
    }

    mutating func find(_ x: T) -> T {
        guard let p = parent[x] else { return x }
        if p != x {
            parent[x] = find(p)
        }
        return parent[x]!
    }

    mutating func union(_ x: T, _ y: T) {
        let rx = find(x)
        let ry = find(y)
        guard rx != ry else { return }

        let rankX = rank[rx, default: 0]
        let rankY = rank[ry, default: 0]
        if rankX < rankY {
            parent[rx] = ry
        } else if rankX > rankY {
            parent[ry] = rx
        } else {
            parent[ry] = rx
            rank[rx] = rankX + 1
        }
    }

    /// Returns groups of 2+ elements that share the same root.
    mutating func groups() -> [[T]] {
        var map: [T: [T]] = [:]
        for key in parent.keys {
            let root = find(key)
            map[root, default: []].append(key)
        }
        return map.values.filter { $0.count >= 2 }
    }
}

// MARK: - DuplicateService

/// Stateless service that detects duplicate library items using Zotero-style heuristics.
///
/// Algorithm (2-pass with Union-Find):
///   Pass 1: DOI match (exact, case-insensitive) → union
///   Pass 2: Normalized title + creator/year verification → union
///
/// Excludes markdown (note) items from detection.
enum DuplicateService {

    /// Find duplicate groups from the given items.
    /// Returns array of groups, each containing 2+ items that are likely duplicates.
    static func findDuplicates(in items: [LibraryItem]) -> [[LibraryItem]] {
        // Exclude notes/markdown items
        let candidates = items.filter { $0.itemType != .markdown }
        guard candidates.count >= 2 else { return [] }

        var uf = DisjointSetForest<UUID>()
        for item in candidates {
            uf.makeSet(item.id)
        }

        // Pass 1: DOI match
        var doiMap: [String: UUID] = [:]
        for item in candidates {
            guard let doi = itemDOI(item), !doi.isEmpty else { continue }
            let normalized = doi.lowercased().trimmingCharacters(in: .whitespaces)
            if let existing = doiMap[normalized] {
                uf.union(existing, item.id)
            } else {
                doiMap[normalized] = item.id
            }
        }

        // Pass 2: Normalized title match with creator/year verification
        var titleMap: [String: [UUID]] = [:]
        for item in candidates {
            let normTitle = normalizeTitle(item.title)
            guard !normTitle.isEmpty else { continue }
            titleMap[normTitle, default: []].append(item.id)
        }

        let itemById = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

        for (_, ids) in titleMap where ids.count >= 2 {
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let a = itemById[ids[i]]!
                    let b = itemById[ids[j]]!
                    if shouldMergeByTitle(a, b) {
                        uf.union(a.id, b.id)
                    }
                }
            }
        }

        // Build groups
        let idGroups = uf.groups()
        return idGroups.compactMap { group in
            let items = group.compactMap { itemById[$0] }
            return items.count >= 2 ? items : nil
        }
    }

    // MARK: - Title Normalization (Zotero-style)

    /// Normalize a title for comparison: strip diacritics, replace punctuation with spaces,
    /// collapse whitespace, trim, lowercase.
    static func normalizeTitle(_ title: String) -> String {
        var s = title
        // Strip diacritics
        if let transformed = s.applyingTransform(.stripDiacritics, reverse: false) {
            s = transformed
        }
        // Replace non-alphanumeric with spaces
        s = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        // Collapse whitespace, trim, lowercase
        s = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        s = s.lowercased()
        return s
    }

    // MARK: - Title + Creator Matching

    /// Determine if two items with the same normalized title should be merged.
    private static func shouldMergeByTitle(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        // If both have DOIs and they differ → skip
        let doiA = itemDOI(a)
        let doiB = itemDOI(b)
        if let da = doiA, !da.isEmpty, let db = doiB, !db.isEmpty {
            if da.lowercased() != db.lowercased() {
                return false
            }
        }

        // If both have years and differ by more than 1 → skip
        let yearA = itemYear(a)
        let yearB = itemYear(b)
        if let ya = yearA, let yb = yearB {
            if abs(ya - yb) > 1 {
                return false
            }
        }

        // Creator matching
        let creatorsA = itemCreators(a)
        let creatorsB = itemCreators(b)
        let hasCreatorsA = !creatorsA.isEmpty
        let hasCreatorsB = !creatorsB.isEmpty

        if hasCreatorsA && hasCreatorsB {
            // Require at least one last-name + first-initial match
            return creatorsA.contains { ca in
                creatorsB.contains { cb in
                    creatorsMatch(ca, cb)
                }
            }
        } else if !hasCreatorsA && !hasCreatorsB {
            // Neither has creators → match
            return true
        } else {
            // Only one has creators → skip
            return false
        }
    }

    // MARK: - Creator Comparison

    private struct CreatorInfo {
        var family: String  // lowercased
        var givenInitial: Swift.Character?  // first character of given name, lowercased
    }

    private static func creatorsMatch(_ a: CreatorInfo, _ b: CreatorInfo) -> Bool {
        guard a.family == b.family else { return false }
        // If both have initials, they must match
        if let ia = a.givenInitial, let ib = b.givenInitial {
            return ia == ib
        }
        // If one or both lack initials, last name match is sufficient
        return true
    }

    // MARK: - Data Access Helpers

    private static func itemDOI(_ item: LibraryItem) -> String? {
        item.referenceMetadata?.doi
    }

    private static func itemYear(_ item: LibraryItem) -> Int? {
        item.referenceMetadata?.year
    }

    private static func itemCreators(_ item: LibraryItem) -> [CreatorInfo] {
        // Try CSL authors first
        if let authors = item.referenceMetadata?.cslItem.author, !authors.isEmpty {
            return authors.compactMap { name -> CreatorInfo? in
                let family = (name.family ?? name.literal ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                guard !family.isEmpty else { return nil }
                let initial = name.given?.first.map { Swift.Character($0.lowercased()) }
                return CreatorInfo(family: family, givenInitial: initial)
            }
        }
        // Fall back to item.author string
        return parseAuthorString(item.author)
    }

    /// Parse a plain author string like "Smith, J.; Doe, A." into creator infos.
    private static func parseAuthorString(_ authorString: String) -> [CreatorInfo] {
        guard !authorString.isEmpty else { return [] }

        // Split by common separators: semicolons, " and ", " & "
        let separators = [";", " and ", " & "]
        var authors = [authorString]
        for sep in separators {
            authors = authors.flatMap { $0.components(separatedBy: sep) }
        }

        return authors.compactMap { part -> CreatorInfo? in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            // Try "Family, Given" format
            let comps = trimmed.components(separatedBy: ",")
            if comps.count >= 2 {
                let family = comps[0].trimmingCharacters(in: .whitespaces).lowercased()
                let given = comps[1].trimmingCharacters(in: .whitespaces)
                guard !family.isEmpty else { return nil }
                return CreatorInfo(family: family, givenInitial: given.first.map { Swift.Character($0.lowercased()) })
            }

            // Try "Given Family" format (take last word as family)
            let words = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if words.count >= 2 {
                let family = words.last!.lowercased()
                let initial = words.first!.first.map { Swift.Character($0.lowercased()) }
                return CreatorInfo(family: family, givenInitial: initial)
            }

            // Single name
            return CreatorInfo(family: trimmed.lowercased(), givenInitial: nil)
        }
    }
}
