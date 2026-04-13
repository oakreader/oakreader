import Foundation
import SwiftData
import PDFKit

@Observable
final class LibraryStore {
    let modelContainer: ModelContainer
    private let modelContext: ModelContext

    // Search & filter state
    var searchText: String = ""
    var currentFilter: LibraryFilter = .all
    var currentSort: LibrarySortOrder = .dateAdded
    var sortAscending: Bool = false
    var selectedCollection: PDFCollection?
    var selectedTags: Set<UUID> = []

    // Observation trigger — bump this to force computed properties to re-evaluate
    private(set) var revision: Int = 0

    init() {
        let schema = Schema([PDFLibraryItem.self, PDFCollection.self, PDFTag.self, ChatSessionMeta.self])
        let config = ModelConfiguration(
            "OakReaderLibrary",
            schema: schema,
            cloudKitDatabase: .automatic
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fallback without CloudKit if entitlements aren't set up
            let localConfig = ModelConfiguration("OakReaderLibrary", schema: schema)
            modelContainer = try! ModelContainer(for: schema, configurations: [localConfig])
        }
        modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = true
    }

    // MARK: - Library Items

    var items: [PDFLibraryItem] {
        _ = revision  // tracked by Observation — triggers re-fetch on mutation
        let descriptor = FetchDescriptor<PDFLibraryItem>(
            sortBy: [sortDescriptor]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    var filteredItems: [PDFLibraryItem] {
        var results = items

        // Apply filter
        switch currentFilter {
        case .all:
            break
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            results = results.filter { $0.dateAdded >= cutoff }
        case .favorites:
            results = results.filter { $0.isFavorite }
        }

        // Apply collection filter
        if let collection = selectedCollection {
            results = results.filter { $0.collections.contains(where: { $0.id == collection.id }) }
        }

        // Apply tag filter — items must have ALL selected tags
        if !selectedTags.isEmpty {
            results = results.filter { item in
                selectedTags.allSatisfy { tagID in
                    item.tags.contains(where: { $0.id == tagID })
                }
            }
        }

        // Apply search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            results = results.filter {
                $0.title.lowercased().contains(query) ||
                $0.author.lowercased().contains(query) ||
                $0.fileName.lowercased().contains(query)
            }
        }

        return results
    }

    private var sortDescriptor: SortDescriptor<PDFLibraryItem> {
        switch currentSort {
        case .dateAdded:
            return SortDescriptor(\.dateAdded, order: sortAscending ? .forward : .reverse)
        case .dateOpened:
            return SortDescriptor(\.dateLastOpened, order: sortAscending ? .forward : .reverse)
        case .title:
            return SortDescriptor(\.title, order: sortAscending ? .forward : .reverse)
        case .author:
            return SortDescriptor(\.author, order: sortAscending ? .forward : .reverse)
        case .fileSize:
            return SortDescriptor(\.fileSize, order: sortAscending ? .forward : .reverse)
        }
    }

    // MARK: - CRUD

    @discardableResult
    func addItem(from url: URL) -> PDFLibraryItem? {
        // Check if already in library
        if let existing = findItem(for: url) {
            existing.dateLastOpened = Date()
            return existing
        }

        let item = PDFLibraryItem(fileName: url.lastPathComponent)
        item.setFileURL(url)

        // Read PDF metadata
        if let pdfDoc = PDFDocument(url: url) {
            item.pageCount = pdfDoc.pageCount
            if let title = pdfDoc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
                item.title = title
            }
            if let author = pdfDoc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
                item.author = author
            }
        }

        // File size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            item.fileSize = size
        }

        modelContext.insert(item)
        try? modelContext.save()
        revision += 1
        return item
    }

    func removeItem(_ item: PDFLibraryItem) {
        modelContext.delete(item)
        try? modelContext.save()
        revision += 1
    }

    func findItem(for url: URL) -> PDFLibraryItem? {
        let fileName = url.lastPathComponent
        let descriptor = FetchDescriptor<PDFLibraryItem>(
            predicate: #Predicate { $0.fileName == fileName }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func toggleFavorite(_ item: PDFLibraryItem) {
        item.isFavorite.toggle()
        try? modelContext.save()
        revision += 1
    }

    func markOpened(_ item: PDFLibraryItem) {
        item.dateLastOpened = Date()
        try? modelContext.save()
        revision += 1
    }

    func updateCover(_ item: PDFLibraryItem, imageData: Data) {
        item.coverImageData = imageData
        try? modelContext.save()
        revision += 1
    }

    // MARK: - Collections

    var collections: [PDFCollection] {
        _ = revision  // tracked by Observation
        let descriptor = FetchDescriptor<PDFCollection>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Root collections (no parent) — for sidebar tree display
    var rootCollections: [PDFCollection] {
        collections.filter { $0.parent == nil }
    }

    @discardableResult
    func createCollection(name: String, icon: String = "folder") -> PDFCollection {
        let collection = PDFCollection(name: name, icon: icon, sortOrder: collections.count)
        modelContext.insert(collection)
        try? modelContext.save()
        revision += 1
        return collection
    }

    @discardableResult
    func createSubcollection(name: String, icon: String = "folder", parent: PDFCollection) -> PDFCollection {
        let collection = PDFCollection(name: name, icon: icon, sortOrder: parent.subcollections.count)
        collection.parent = parent
        modelContext.insert(collection)
        try? modelContext.save()
        revision += 1
        return collection
    }

    func moveCollection(_ collection: PDFCollection, toParent newParent: PDFCollection?) {
        collection.parent = newParent
        try? modelContext.save()
        revision += 1
    }

    func deleteCollection(_ collection: PDFCollection) {
        modelContext.delete(collection)
        if selectedCollection?.id == collection.id {
            selectedCollection = nil
        }
        try? modelContext.save()
        revision += 1
    }

    func renameCollection(_ collection: PDFCollection, to name: String) {
        collection.name = name
        try? modelContext.save()
        revision += 1
    }

    func addItem(_ item: PDFLibraryItem, to collection: PDFCollection) {
        if !collection.items.contains(where: { $0.id == item.id }) {
            collection.items.append(item)
            try? modelContext.save()
            revision += 1
        }
    }

    func removeItem(_ item: PDFLibraryItem, from collection: PDFCollection) {
        collection.items.removeAll { $0.id == item.id }
        try? modelContext.save()
        revision += 1
    }

    /// Import all PDFs from a folder, creating a collection named after the folder.
    /// Returns the number of PDFs imported.
    @discardableResult
    func importFolder(_ folderURL: URL) -> Int {
        let folderName = folderURL.lastPathComponent
        let collection = createCollection(name: folderName, icon: "folder.fill")

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "pdf" else { continue }
            if let item = addItem(from: fileURL) {
                addItem(item, to: collection)
                count += 1
            }
        }

        selectedCollection = collection
        return count
    }

    // MARK: - Tags

    var tags: [PDFTag] {
        _ = revision  // tracked by Observation
        let descriptor = FetchDescriptor<PDFTag>(
            sortBy: [SortDescriptor(\.position)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    @discardableResult
    func createTag(name: String, color: TagColor) -> PDFTag {
        let tag = PDFTag(name: name, colorHex: color.hex, position: tags.count)
        modelContext.insert(tag)
        try? modelContext.save()
        revision += 1
        return tag
    }

    func deleteTag(_ tag: PDFTag) {
        selectedTags.remove(tag.id)
        modelContext.delete(tag)
        try? modelContext.save()
        revision += 1
    }

    func renameTag(_ tag: PDFTag, to name: String) {
        tag.name = name
        try? modelContext.save()
        revision += 1
    }

    func updateTagColor(_ tag: PDFTag, to color: TagColor) {
        tag.colorHex = color.hex
        try? modelContext.save()
        revision += 1
    }

    func addTag(_ tag: PDFTag, to item: PDFLibraryItem) {
        if !item.tags.contains(where: { $0.id == tag.id }) {
            item.tags.append(tag)
            try? modelContext.save()
            revision += 1
        }
    }

    func removeTag(_ tag: PDFTag, from item: PDFLibraryItem) {
        item.tags.removeAll { $0.id == tag.id }
        try? modelContext.save()
        revision += 1
    }
}
