import Foundation
import GRDB

// MARK: - Command Handlers

struct CLICommands {
    let db: CLIDatabase
    let resolver: CLIResolver

    init(db: CLIDatabase) {
        self.db = db
        self.resolver = CLIResolver(db: db)
    }

    // MARK: - Root (stats)

    func runStats() throws {
        let stats = try db.fetchStats()
        print(CLIFormatters.formatStats(items: stats.items, collections: stats.collections, tags: stats.tags))
    }

    // MARK: - Items

    func runItemsList(args: [String], flags: ParsedFlags) throws {
        let items = try db.fetchAllItems(
            collectionName: flags["collection"],
            tagName: flags["tag"],
            type: flags["type"],
            search: flags["search"],
            sort: flags["sort"],
            limit: flags["limit"].flatMap(Int.init)
        )
        print(CLIFormatters.formatItemList(items))
    }

    func runItemsShow(args: [String]) throws {
        guard !args.isEmpty else {
            printError("Usage: oak items show <item>")
            return
        }
        let input = args.joined(separator: " ")
        let item = try resolver.resolveItem(input)
        guard let result = try db.fetchItem(id: item.id) else {
            printError("Item not found.")
            return
        }
        let tags = try db.fetchItemTags(itemId: item.id)
        let status = try db.fetchItemStatus(itemId: item.id)
        let collections = try db.fetchItemCollections(itemId: item.id)
        print(CLIFormatters.formatItemDetail(
            item: result.item,
            attachments: result.attachments,
            tags: tags,
            status: status,
            collections: collections
        ))
    }

    func runItemsOpen(args: [String]) throws {
        guard !args.isEmpty else {
            printError("Usage: oak items open <item>")
            return
        }
        let input = args.joined(separator: " ")
        let item = try resolver.resolveItem(input)

        // Build the custom URL scheme to open in OakReader.app
        let urlString = "oakreader://open/\(item.id)"
        guard let url = URL(string: urlString) else {
            printError("Failed to construct URL.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()
        print("Opening '\(item.title)' in OakReader...")
    }

    // MARK: - Collections

    func runCollectionsList() throws {
        let collections = try db.fetchAllCollections()
        var counts: [String: Int] = [:]
        for c in collections {
            counts[c.id] = try db.fetchCollectionItemCount(collectionId: c.id)
        }
        print(CLIFormatters.formatCollectionTree(collections, counts: counts))
    }

    func runCollectionsCreate(args: [String], flags: ParsedFlags) throws {
        guard let name = args.first else {
            printError("Usage: oak collections create <name> [--parent <name>]")
            return
        }

        var parentId: String? = nil
        if let parentName = flags["parent"] {
            let parent = try resolver.resolveParentCollection(parentName)
            parentId = parent.id
        }

        let id = try db.createCollection(name: name, parentId: parentId)
        print("Created collection '\(name)' [\(id.prefix(8))]")
    }

    func runCollectionsRename(args: [String]) throws {
        guard args.count >= 2 else {
            printError("Usage: oak collections rename <name|id> <new-name>")
            return
        }
        let identifier = args[0]
        let newName = args[1]

        let collection = try resolver.resolveCollection(identifier)
        if CLISystemCollectionID.all.contains(collection.id) {
            printError("Cannot rename system collection '\(collection.name)'.")
            return
        }
        try db.renameCollection(id: collection.id, newName: newName)
        print("Renamed collection '\(collection.name)' -> '\(newName)'")
    }

    func runCollectionsDelete(args: [String]) throws {
        guard !args.isEmpty else {
            printError("Usage: oak collections delete <name|id>")
            return
        }
        let input = args.joined(separator: " ")
        let collection = try resolver.resolveCollection(input)
        if CLISystemCollectionID.all.contains(collection.id) {
            printError("Cannot delete system collection '\(collection.name)'.")
            return
        }
        try db.deleteCollection(id: collection.id)
        print("Deleted collection '\(collection.name)'")
    }

    func runCollectionsAdd(args: [String]) throws {
        guard args.count >= 2 else {
            printError("Usage: oak collections add <collection> <item>")
            return
        }
        let collection = try resolver.resolveCollection(args[0])
        let item = try resolver.resolveItem(args[1])
        if collection.isSmart || collection.isSystem {
            printError("Cannot manually add items to smart/system collection '\(collection.name)'.")
            return
        }
        try db.addItemToCollection(collectionId: collection.id, itemId: item.id)
        print("Added '\(item.title)' to collection '\(collection.name)'")
    }

    func runCollectionsRemove(args: [String]) throws {
        guard args.count >= 2 else {
            printError("Usage: oak collections remove <collection> <item>")
            return
        }
        let collection = try resolver.resolveCollection(args[0])
        let item = try resolver.resolveItem(args[1])
        try db.removeItemFromCollection(collectionId: collection.id, itemId: item.id)
        print("Removed '\(item.title)' from collection '\(collection.name)'")
    }

    // MARK: - Tags

    func runTagsList() throws {
        let tags = try db.fetchAllTags()
        print(CLIFormatters.formatTagList(tags))
    }

    func runTagsCreate(args: [String], flags: ParsedFlags) throws {
        guard let name = args.first else {
            printError("Usage: oak tags create <name> [--color <hex>]")
            return
        }
        let color = flags["color"]
        let id = try db.createTag(name: name, colorHex: color)
        print("Created tag '\(name)' [\(id.prefix(8))]")
    }

    func runTagsRename(args: [String]) throws {
        guard args.count >= 2 else {
            printError("Usage: oak tags rename <name|id> <new-name>")
            return
        }
        let tag = try resolver.resolveTag(args[0])
        let newName = args[1]
        try db.renameTag(id: tag.id, newName: newName)
        print("Renamed tag '\(tag.name)' -> '\(newName)'")
    }

    func runTagsDelete(args: [String]) throws {
        guard !args.isEmpty else {
            printError("Usage: oak tags delete <name|id>")
            return
        }
        let input = args.joined(separator: " ")
        let tag = try resolver.resolveTag(input)
        try db.deleteTag(id: tag.id)
        print("Deleted tag '\(tag.name)'")
    }

    func runTagsAdd(args: [String]) throws {
        guard args.count >= 2 else {
            printError("Usage: oak tags add <tag> <item>")
            return
        }
        let tag = try resolver.resolveTag(args[0])
        let item = try resolver.resolveItem(args[1])
        try db.addTagToItem(tagId: tag.id, itemId: item.id)
        print("Tagged '\(item.title)' with '\(tag.name)'")
    }

    func runTagsRemove(args: [String]) throws {
        guard args.count >= 2 else {
            printError("Usage: oak tags remove <tag> <item>")
            return
        }
        let tag = try resolver.resolveTag(args[0])
        let item = try resolver.resolveItem(args[1])
        try db.removeTagFromItem(tagId: tag.id, itemId: item.id)
        print("Removed tag '\(tag.name)' from '\(item.title)'")
    }

    // MARK: - Import

    func runImport(args: [String], flags: ParsedFlags) throws -> Bool {
        guard let input = args.first else {
            printError("Usage: oak import <file|url> [--title <title>] [--collection <name>] [--tag <name>]")
            return false
        }

        let titleOverride = flags["title"]
        let importer = CLIImporter(db: db)
        let result: CLIImporter.ImportResult

        // Detect if input is a URL or file path
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            // URL import — needs async, return false to signal caller
            return false
        } else {
            // Local file import
            let fileURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ImportError.fileNotFound(input)
            }

            let ext = fileURL.pathExtension.lowercased()
            switch ext {
            case "pdf":
                result = try importer.importPDF(from: fileURL, title: titleOverride)
            case "html", "htm":
                result = try importer.importHTML(from: fileURL, title: titleOverride)
            case "md", "markdown":
                result = try importer.importMarkdown(from: fileURL, title: titleOverride)
            default:
                throw ImportError.unsupportedType(ext.isEmpty ? "(none)" : ".\(ext)")
            }
        }

        if result.isDuplicate {
            print("Already imported '\(result.title)' [\(result.itemId.prefix(8))]")
        } else {
            // Apply --collection and --tag flags
            applyPostImportFlags(itemId: result.itemId, flags: flags)
            print("Imported '\(result.title)' [\(result.itemId.prefix(8))]")
        }

        return true
    }

    func runImportAsync(args: [String], flags: ParsedFlags) async throws {
        guard let input = args.first else {
            printError("Usage: oak import <file|url> [--title <title>] [--collection <name>] [--tag <name>]")
            return
        }

        let titleOverride = flags["title"]
        let importer = CLIImporter(db: db)

        let result = try await importer.importURL(input, title: titleOverride)

        if result.isDuplicate {
            print("Already imported '\(result.title)' [\(result.itemId.prefix(8))]")
        } else {
            applyPostImportFlags(itemId: result.itemId, flags: flags)
            print("Imported '\(result.title)' [\(result.itemId.prefix(8))]")
        }
    }

    private func applyPostImportFlags(itemId: String, flags: ParsedFlags) {
        if let collectionName = flags["collection"] {
            do {
                let collection = try resolver.resolveCollection(collectionName)
                try db.addItemToCollection(collectionId: collection.id, itemId: itemId)
            } catch {
                printError("Failed to add to collection '\(collectionName)': \(error.localizedDescription)")
            }
        }

        if let tagName = flags["tag"] {
            do {
                let tag = try resolver.resolveTag(tagName)
                try db.addTagToItem(tagId: tag.id, itemId: itemId)
            } catch {
                printError("Failed to add tag '\(tagName)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Search

    /// `oak search <query> [--mode keyword|semantic|hybrid] [--limit N]`
    func runSearch(args: [String], flags: ParsedFlags) throws {
        let query = args.joined(separator: " ")
        guard !query.isEmpty else {
            printError("Usage: oak search <query> [--mode keyword|semantic|hybrid] [--limit N]")
            return
        }
        let mode = flags["mode"] ?? "keyword"
        let limit = Int(flags["limit"] ?? "20") ?? 20

        switch mode {
        case "keyword":
            let results = try db.keywordSearch(query: query, limit: limit)
            print(CLIFormatters.formatSearchResults(results, query: query, mode: "keyword"))
        case "semantic", "hybrid":
            printError("Semantic search requires the OakReader app (MLX embedding model). Use --mode keyword in the CLI.")
        default:
            printError("Unknown search mode '\(mode)'. Use keyword, semantic, or hybrid.")
        }
    }

    /// Async search for semantic and hybrid modes.
    func runSearchAsync(args: [String], flags: ParsedFlags) async throws {
        let query = args.joined(separator: " ")
        guard !query.isEmpty else {
            printError("Usage: oak search <query> [--mode keyword|semantic|hybrid] [--limit N]")
            return
        }
        let mode = flags["mode"] ?? "keyword"
        let limit = Int(flags["limit"] ?? "20") ?? 20

        switch mode {
        case "keyword":
            let results = try db.keywordSearch(query: query, limit: limit)
            print(CLIFormatters.formatSearchResults(results, query: query, mode: "keyword"))

        case "semantic", "hybrid":
            printError("Semantic search requires the OakReader app (MLX embedding model). Use --mode keyword in the CLI.")

        default:
            printError("Unknown search mode '\(mode)'. Use keyword, semantic, or hybrid.")
        }
    }

    // MARK: - Status

    func runStatus(args: [String]) throws {
        guard !args.isEmpty else {
            printError("Usage: oak status <item> [<value>]")
            return
        }

        if args.count == 1 {
            // Show status
            let item = try resolver.resolveItem(args[0])
            let status = try db.fetchItemStatus(itemId: item.id)
            print(CLIFormatters.formatStatus(item: item, status: status))
        } else {
            // Set status
            let item = try resolver.resolveItem(args[0])
            let statusOption = try resolver.resolveStatus(args[1])
            try db.setItemStatus(itemId: item.id, statusOptionId: statusOption.id)
            print("Set status of '\(item.title)' to '\(statusOption.name)'")
        }
    }
}

// MARK: - Flag Parsing

typealias ParsedFlags = [String: String]

func parseFlags(_ args: inout [String]) -> ParsedFlags {
    var flags: ParsedFlags = [:]
    var remaining: [String] = []
    var i = 0

    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                flags[key] = args[i + 1]
                i += 2
            } else {
                flags[key] = ""
                i += 1
            }
        } else {
            remaining.append(arg)
            i += 1
        }
    }

    args = remaining
    return flags
}

func printError(_ message: String) {
    fputs("Error: \(message)\n", stderr)
}
