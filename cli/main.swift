import ArgumentParser
import Foundation
import OakAgent
import PDFKit

// MARK: - Library Change Notifications

enum CLILibraryChangeNotifier {
    static let source = "oak-cli"
    static let notificationName = Notification.Name("com.oakreader.library.didChange")

    static func post(operation: String, message: String, id: String? = nil) {
        var userInfo: [String: String] = [
            "source": source,
            "operation": operation,
            "message": message,
        ]
        if let id { userInfo["id"] = id }

        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: source,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}

// MARK: - Global Options

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Output results as JSON.")
    var json = false

    @Flag(name: .long, help: "Suppress non-essential output.")
    var quiet = false

    @Option(name: .long, help: "Path to database (default: the app's library.sqlite).")
    var db: String?
}

// MARK: - Root Command

struct Oak: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oak",
        abstract: "OakReader CLI",
        version: "1.0.0",
        subcommands: [
            Items.self,
            Collections.self,
            Tags.self,
            Import.self,
            Search.self,
            Status.self,
            Open.self,
            Skills.self,
            Words.self,
            Notes.self,
        ],
        defaultSubcommand: nil
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let output = CLIOutput(json: globals.json, quiet: globals.quiet)

        let stats = try database.fetchStats()

        if globals.json {
            output.success(operation: "stats", result: CLIStats(
                items: stats.items, collections: stats.collections, tags: stats.tags
            ))
        } else {
            print(CLIFormatters.formatStats(items: stats.items, collections: stats.collections, tags: stats.tags))
            print("")
            print("Run 'oak --help' for available commands.")
        }
    }
}

// MARK: - Words (lookup history)

struct Words: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "words",
        abstract: "List words you looked up while reading (newest first)."
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Only words looked up today.")
    var today = false

    @Option(name: .long, help: "Only words looked up on or after this date (YYYY-MM-DD).")
    var since: String?

    @Option(name: .long, help: "Maximum number of results (default 100).")
    var limit: Int?

    @Flag(name: .long, help: "Output as CSV (Word, Sentence, Explanation, Document, Created At).")
    var csv = false

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let sinceISO = try Words.resolveSince(today: today, since: since)
        let lookups = try database.fetchWordLookups(since: sinceISO, limit: limit ?? 100)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.results(operation: "words.list", items: lookups, meta: ["count": lookups.count])
            return
        }

        if csv {
            print(Words.csvString(lookups))
            return
        }

        guard !lookups.isEmpty else {
            print(today ? "No words looked up today." : "No word lookups found.")
            return
        }
        for l in lookups {
            let sentence = l.sentence.replacingOccurrences(of: "\n", with: " ")
            let snippet = sentence.count > 64 ? String(sentence.prefix(64)) + "…" : sentence
            let doc = l.itemTitle.isEmpty ? "" : "  (\(l.itemTitle))"
            print("\(l.word)  —  \(snippet)\(doc)  ·  \(Words.shortDate(l.createdAt))")
        }
        if !globals.quiet {
            print("\n\(lookups.count) word\(lookups.count == 1 ? "" : "s").")
        }
    }

    /// Resolve `--today` / `--since` to an ISO8601 UTC lower bound matching the
    /// stored timestamps' format, or nil for no lower bound.
    static func resolveSince(today: Bool, since: String?) throws -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if today {
            return iso.string(from: Calendar.current.startOfDay(for: Date()))
        }
        if let since {
            let day = DateFormatter()
            day.calendar = Calendar(identifier: .gregorian)
            day.dateFormat = "yyyy-MM-dd"
            guard let date = day.date(from: since) else {
                throw ValidationError("Invalid --since date '\(since)'. Use YYYY-MM-DD.")
            }
            return iso.string(from: Calendar.current.startOfDay(for: date))
        }
        return nil
    }

    /// Render lookups as CSV with a header row. Created-at stays in the stored
    /// ISO8601 form so it round-trips with `--json`.
    static func csvString(_ lookups: [CLIWordLookup]) -> String {
        func escape(_ field: String) -> String {
            "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = ["Word,Sentence,Explanation,Document,Created At"]
        for l in lookups {
            rows.append([l.word, l.sentence, l.explanation, l.itemTitle, l.createdAt]
                .map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    /// Render a stored ISO8601 timestamp as a short local "MMM d, HH:mm".
    static func shortDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMM d, HH:mm"
        return out.string(from: date)
    }
}

// MARK: - Notes

struct Notes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "List or export the notes you wrote while reading.",
        discussion: """
        Notes live in OakReader's library database, not on disk. This is how you \
        get them out — as a readable list, structured JSON, or one combined \
        Markdown document you can pipe anywhere:

            oak notes                                    # every note, newest first
            oak notes --item "Measuring Agents"          # just one document's notes
            oak notes --markdown | pbcopy                # copy all notes as Markdown
            oak notes --item paper2512 --markdown        # (resolves title / cite key / id)
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Only notes for this item (title, cite key, or ID).")
    var item: String?

    @Option(name: .long, help: "Only notes created on or after this date (YYYY-MM-DD).")
    var since: String?

    @Option(name: .long, help: "Maximum number of notes (newest first).")
    var limit: Int?

    @Flag(name: .long, help: "Output one combined Markdown document (pipeable to pbcopy).")
    var markdown = false

    func run() throws {
        let database = try CLIDatabase(path: globals.db)

        // Resolve the optional item filter, and the title used for the Markdown heading.
        var itemId: String?
        var title = "Library"
        if let item {
            let resolved = try CLIResolver(db: database).resolveItem(item)
            itemId = resolved.id
            title = resolved.title
        }

        let sinceISO = try Words.resolveSince(today: false, since: since)
        let notes = try database.fetchNotes(itemId: itemId, since: sinceISO, limit: limit)

        if markdown {
            // Markdown wins over --json: it's the copy-to-clipboard / paste-into-vault path.
            print(CLIFormatters.notesMarkdown(notes, title: title))
            return
        }

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.results(operation: "notes.list", items: notes, meta: ["count": notes.count])
            return
        }

        guard !notes.isEmpty else {
            print(item == nil ? "No notes yet." : "No notes for '\(title)'.")
            return
        }
        for note in notes {
            let preview = CLIFormatters.truncate(
                note.comment.replacingOccurrences(of: "\n", with: " "), to: 72
            )
            let doc = item == nil && !note.itemTitle.isEmpty ? "  (\(note.itemTitle))" : ""
            print("\(CLIFormatters.noteTimestamp(note.createdAt))  —  \(preview)\(doc)")
        }
        if !globals.quiet {
            print("\n\(notes.count) note\(notes.count == 1 ? "" : "s").")
        }
    }
}

// MARK: - Items

struct Items: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage library items.",
        subcommands: [ItemsList.self, ItemsShow.self, ItemsRead.self, ItemsOpen.self],
        defaultSubcommand: ItemsList.self
    )
}

struct ItemsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List items.")

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Filter by collection name.")
    var collection: String?

    @Option(name: .long, help: "Filter by tag name.")
    var tag: String?

    @Option(name: .long, help: "Filter by type (pdf, web, video, note).")
    var type: String?

    @Option(name: .long, help: "Search query.")
    var search: String?

    @Option(name: .long, help: "Sort by: title, author, date.")
    var sort: String?

    @Option(name: .long, help: "Maximum number of results.")
    var limit: Int?

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let items = try database.fetchAllItems(
            collectionName: collection,
            tagName: tag,
            type: type,
            search: search,
            sort: sort,
            limit: limit
        )

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            let results = items.map { CLIItemResult(item: $0.item, attachments: $0.attachments) }
            output.results(operation: "items.list", items: results, meta: ["count": items.count])
        } else {
            print(CLIFormatters.formatItemList(items))
        }
    }
}

struct ItemsShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show item detail.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Item identifier (title, cite key, or ID).")
    var item: String

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let resolved = try resolver.resolveItem(item)

        guard let result = try database.fetchItem(id: resolved.id) else {
            throw OakError.notFound("item", item)
        }

        let tags = try database.fetchItemTags(itemId: resolved.id)
        let status = try database.fetchItemStatus(itemId: resolved.id)
        let collections = try database.fetchItemCollections(itemId: resolved.id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            let detail = CLIItemDetail(
                item: result.item,
                attachments: result.attachments,
                tags: tags,
                status: status,
                collections: collections
            )
            output.success(operation: "items.show", result: detail)
        } else {
            print(CLIFormatters.formatItemDetail(
                item: result.item,
                attachments: result.attachments,
                tags: tags,
                status: status,
                collections: collections
            ))
        }
    }
}

struct ItemsRead: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "read", abstract: "Read item content (extract text).")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Item identifier (title, cite key, or ID).")
    var item: String

    @Option(name: .long, help: "Page range for PDFs (e.g. \"1-5\", \"3,7,12\"). Omit for all pages.")
    var pages: String?

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let resolved = try resolver.resolveItem(item)

        guard let filePath = try database.fetchItemFilePath(itemId: resolved.id) else {
            throw OakError.general("No primary attachment found for '\(resolved.title)'.")
        }

        let url = filePath.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OakError.general("File not found: \(url.path)")
        }

        let text: String
        switch filePath.contentType {
        case "pdf":
            text = try extractPDFText(url: url, pageCount: filePath.pageCount, pagesParam: pages)
        case "html":
            text = try extractHTMLText(url: url)
        case "markdown":
            text = try extractTextFile(url: url)
        default:
            throw OakError.general("Unsupported content type '\(filePath.contentType)' for text extraction.")
        }

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "items.read", result: CLIReadResult(
                title: resolved.title,
                citeKey: resolved.citeKey,
                contentType: filePath.contentType,
                pageCount: filePath.pageCount,
                content: String(text.prefix(100_000))
            ))
        } else {
            print(text.prefix(100_000))
        }
    }

    // MARK: - Text Extraction

    private func extractPDFText(url: URL, pageCount: Int, pagesParam: String?) throws -> String {
        // Prefer structured content.md when reading the full document
        if pagesParam == nil {
            let mdURL = url.deletingLastPathComponent().appendingPathComponent("content.md")
            if let markdown = try? String(contentsOf: mdURL, encoding: .utf8), !markdown.isEmpty {
                return markdown
            }
        }

        guard let pdf = PDFDocument(url: url) else {
            throw OakError.general("Failed to open PDF at \(url.path)")
        }

        let pageIndices: [Int]
        if let param = pagesParam, !param.isEmpty {
            pageIndices = parsePDFPageRange(param, maxPage: pdf.pageCount)
            if pageIndices.isEmpty {
                throw OakError.general(
                    "Invalid page range: \"\(param)\". Use formats like \"1-5\" or \"3,7,12\". Document has \(pdf.pageCount) pages."
                )
            }
        } else {
            pageIndices = Array(0..<pdf.pageCount)
        }

        var parts: [String] = []
        for index in pageIndices {
            guard let page = pdf.page(at: index) else { continue }
            let pageText = page.string ?? ""
            if !pageText.isEmpty {
                parts.append("--- Page \(index + 1) ---\n\(pageText)")
            }
        }

        if parts.isEmpty {
            return "No text content found on the requested pages."
        }
        return parts.joined(separator: "\n\n")
    }

    private func extractHTMLText(url: URL) throws -> String {
        // Prefer markdown version (content.md) saved alongside HTML by browser extension
        let mdURL = url.deletingLastPathComponent().appendingPathComponent("content.md")
        if let markdown = try? String(contentsOf: mdURL, encoding: .utf8), !markdown.isEmpty {
            return markdown
        }

        guard let data = try? Data(contentsOf: url) else {
            throw OakError.general("Failed to read HTML file at \(url.path)")
        }

        // Extract text using XMLDocument (same approach as the app)
        guard let doc = try? XMLDocument(data: data, options: .documentTidyHTML),
              let root = doc.rootElement() else {
            return String(data: data, encoding: .utf8) ?? ""
        }

        var parts: [String] = []
        collectHTMLText(from: root, into: &parts)
        return parts.joined()
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractTextFile(url: URL) throws -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw OakError.general("Failed to read file at \(url.path)")
        }
        return content
    }

    // MARK: - HTML Helpers

    private static let suppressedTags: Set<String> = [
        "script", "style", "noscript", "svg", "math"
    ]

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "nav", "main",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre",
        "ul", "ol", "li", "table", "tr", "td", "th",
        "br", "hr", "figcaption", "figure", "details", "summary"
    ]

    private func collectHTMLText(from node: XMLNode, into parts: inout [String]) {
        switch node.kind {
        case .text:
            if let text = node.stringValue, !text.isEmpty {
                parts.append(text)
            }
        case .element:
            guard let element = node as? XMLElement else { return }
            let tag = element.name?.lowercased() ?? ""
            if Self.suppressedTags.contains(tag) { return }
            let isBlock = Self.blockTags.contains(tag)
            if isBlock { parts.append("\n") }
            for child in node.children ?? [] {
                collectHTMLText(from: child, into: &parts)
            }
            if isBlock { parts.append("\n") }
        default:
            for child in node.children ?? [] {
                collectHTMLText(from: child, into: &parts)
            }
        }
    }

    // MARK: - Page Range Parser

    private func parsePDFPageRange(_ input: String, maxPage: Int) -> [Int] {
        var indices: [Int] = []
        let rangeParts = input.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for part in rangeParts {
            if part.contains("-") {
                let bounds = part.split(separator: "-").compactMap {
                    Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard bounds.count == 2, bounds[0] >= 1, bounds[1] >= bounds[0] else { continue }
                let start = max(bounds[0], 1)
                let end = min(bounds[1], maxPage)
                for page in start...end {
                    indices.append(page - 1)
                }
            } else if let page = Int(part), page >= 1, page <= maxPage {
                indices.append(page - 1)
            }
        }
        return indices
    }
}

struct CLIReadResult: Encodable {
    let title: String
    let citeKey: String?
    let contentType: String
    let pageCount: Int
    let content: String
}

struct ItemsOpen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open item in OakReader.app.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Item identifier (title, cite key, or ID).")
    var item: String

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let resolved = try resolver.resolveItem(item)

        let urlString = "oakreader://open/\(resolved.id)"
        guard let url = URL(string: urlString) else {
            throw OakError.general("Failed to construct URL.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "items.open", result: CLIOperationResult(
                id: resolved.id, message: "Opening '\(resolved.title)' in OakReader..."
            ))
        } else {
            print("Opening '\(resolved.title)' in OakReader...")
        }
    }
}

// MARK: - Collections

struct Collections: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage collections.",
        subcommands: [
            CollectionsList.self, CollectionsCreate.self, CollectionsRename.self,
            CollectionsAdd.self, CollectionsRemove.self,
        ],
        defaultSubcommand: CollectionsList.self
    )
}

struct CollectionsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List collections.")

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let collections = try database.fetchAllCollections()
        var counts: [String: Int] = [:]
        for c in collections {
            counts[c.id] = try database.fetchCollectionItemCount(collectionId: c.id)
        }

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            let results = collections.map { c in
                CLICollectionResult(collection: c, count: counts[c.id] ?? 0)
            }
            output.results(operation: "collections.list", items: results, meta: ["count": collections.count])
        } else {
            print(CLIFormatters.formatCollectionTree(collections, counts: counts))
        }
    }
}

struct CollectionsCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a collection.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Collection name.")
    var name: String

    @Option(name: .long, help: "Parent collection name.")
    var parent: String?

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)

        var parentId: String?
        if let parentName = parent {
            let p = try resolver.resolveParentCollection(parentName)
            parentId = p.id
        }

        let id = try database.createCollection(name: name, parentId: parentId)
        CLILibraryChangeNotifier.post(operation: "collections.create", message: "Created collection \"\(name)\"", id: id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "collections.create", result: CLIOperationResult(
                id: id, message: "Created collection '\(name)'"
            ))
        } else {
            print("Created collection '\(name)' [\(id.prefix(8))]")
        }
    }
}

struct CollectionsRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Rename a collection.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Current collection name or ID.")
    var current: String

    @Argument(help: "New name.")
    var newName: String

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let collection = try resolver.resolveCollection(current)

        if CLISystemCollectionID.all.contains(collection.id) {
            throw OakError.general("Cannot rename system collection '\(collection.name)'.")
        }

        try database.renameCollection(id: collection.id, newName: newName)
        CLILibraryChangeNotifier.post(operation: "collections.rename", message: "Renamed collection to \"\(newName)\"", id: collection.id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "collections.rename", result: CLIOperationResult(
                id: collection.id, message: "Renamed '\(collection.name)' -> '\(newName)'"
            ))
        } else {
            print("Renamed collection '\(collection.name)' -> '\(newName)'")
        }
    }
}

struct CollectionsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add item to collection.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Collection name or ID.")
    var collection: String

    @Argument(help: "Item identifier.")
    var item: String

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let col = try resolver.resolveCollection(collection)
        let itm = try resolver.resolveItem(item)

        if col.isSmart || col.isSystem {
            throw OakError.general("Cannot manually add items to smart/system collection '\(col.name)'.")
        }

        try database.addItemToCollection(collectionId: col.id, itemId: itm.id)
        CLILibraryChangeNotifier.post(operation: "collections.add", message: "Added \"\(itm.title)\" to \"\(col.name)\"", id: itm.id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "collections.add", result: CLIOperationResult(
                id: itm.id, message: "Added '\(itm.title)' to '\(col.name)'"
            ))
        } else {
            print("Added '\(itm.title)' to collection '\(col.name)'")
        }
    }
}

struct CollectionsRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove item from collection.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Collection name or ID.")
    var collection: String

    @Argument(help: "Item identifier.")
    var item: String

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let col = try resolver.resolveCollection(collection)
        let itm = try resolver.resolveItem(item)

        try database.removeItemFromCollection(collectionId: col.id, itemId: itm.id)
        CLILibraryChangeNotifier.post(operation: "collections.remove", message: "Removed \"\(itm.title)\" from \"\(col.name)\"", id: itm.id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "collections.remove", result: CLIOperationResult(
                id: itm.id, message: "Removed '\(itm.title)' from '\(col.name)'"
            ))
        } else {
            print("Removed '\(itm.title)' from collection '\(col.name)'")
        }
    }
}

// MARK: - Tags

struct Tags: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage tags.",
        subcommands: [
            TagsList.self, TagsCreate.self, TagsRename.self,
            TagsAdd.self, TagsRemove.self,
        ],
        defaultSubcommand: TagsList.self
    )
}

struct TagsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List tags.")

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let tags = try database.fetchAllTags()

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            let results = tags.map { CLITagResult(tag: $0.tag, count: $0.count) }
            output.results(operation: "tags.list", items: results, meta: ["count": tags.count])
        } else {
            print(CLIFormatters.formatTagList(tags))
        }
    }
}

struct TagsCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a tag.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Tag name.")
    var name: String

    @Option(name: .long, help: "Color hex code (e.g. FF5733).")
    var color: String?

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let id = try database.createTag(name: name, colorHex: color)
        CLILibraryChangeNotifier.post(operation: "tags.create", message: "Created tag \"\(name)\"", id: id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "tags.create", result: CLIOperationResult(
                id: id, message: "Created tag '\(name)'"
            ))
        } else {
            print("Created tag '\(name)' [\(id.prefix(8))]")
        }
    }
}

struct TagsRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Rename a tag.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Current tag name or ID.")
    var current: String

    @Argument(help: "New name.")
    var newName: String

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let tag = try resolver.resolveTag(current)

        try database.renameTag(id: tag.id, newName: newName)
        CLILibraryChangeNotifier.post(operation: "tags.rename", message: "Renamed tag to \"\(newName)\"", id: tag.id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "tags.rename", result: CLIOperationResult(
                id: tag.id, message: "Renamed '\(tag.name)' -> '\(newName)'"
            ))
        } else {
            print("Renamed tag '\(tag.name)' -> '\(newName)'")
        }
    }
}

struct TagsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Tag an item.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Tag name or ID.")
    var tag: String

    @Argument(help: "Item identifier.")
    var item: String

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let t = try resolver.resolveTag(tag)
        let itm = try resolver.resolveItem(item)

        try database.addTagToItem(tagId: t.id, itemId: itm.id)
        CLILibraryChangeNotifier.post(operation: "tags.add", message: "Tagged \"\(itm.title)\" with \"\(t.name)\"", id: itm.id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "tags.add", result: CLIOperationResult(
                id: itm.id, message: "Tagged '\(itm.title)' with '\(t.name)'"
            ))
        } else {
            print("Tagged '\(itm.title)' with '\(t.name)'")
        }
    }
}

struct TagsRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Untag an item.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Tag name or ID.")
    var tag: String

    @Argument(help: "Item identifier.")
    var item: String

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let t = try resolver.resolveTag(tag)
        let itm = try resolver.resolveItem(item)

        try database.removeTagFromItem(tagId: t.id, itemId: itm.id)
        CLILibraryChangeNotifier.post(operation: "tags.remove", message: "Removed tag \"\(t.name)\" from \"\(itm.title)\"", id: itm.id)

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "tags.remove", result: CLIOperationResult(
                id: itm.id, message: "Removed tag '\(t.name)' from '\(itm.title)'"
            ))
        } else {
            print("Removed tag '\(t.name)' from '\(itm.title)'")
        }
    }
}

// MARK: - Import

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import PDF, HTML, Markdown, or URL.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "File path or URL to import.")
    var source: String

    @Option(name: .long, help: "Override title.")
    var title: String?

    @Option(name: .long, help: "Add to collection after import.")
    var collection: String?

    @Option(name: .long, help: "Tag after import.")
    var tag: String?

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let importer = CLIImporter(db: database)

        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            // URL import — needs async
            _ = Task {
                do {
                    let result = try await importer.importURL(source, title: title)
                    self.handleResult(result, database: database, resolver: resolver)
                } catch {
                    if globals.json {
                        let output = CLIOutput(json: true, quiet: globals.quiet)
                        output.error(operation: "import", message: error.localizedDescription, code: "import_failed")
                    } else {
                        fputs("Error: \(error.localizedDescription)\n", stderr)
                    }
                    Darwin.exit(1)
                }
                Darwin.exit(0)
            }
            RunLoop.main.run()
        } else {
            let fileURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw OakError.notFound("file", source)
            }

            let ext = fileURL.pathExtension.lowercased()
            let result: CLIImporter.ImportResult
            switch ext {
            case "pdf":
                result = try importer.importPDF(from: fileURL, title: title)
            case "html", "htm":
                result = try importer.importHTML(from: fileURL, title: title)
            case "md", "markdown":
                result = try importer.importMarkdown(from: fileURL, title: title)
            default:
                throw OakError.general("Unsupported file type: \(ext.isEmpty ? "(none)" : ".\(ext)")")
            }

            handleResult(result, database: database, resolver: resolver)
        }
    }

    private func handleResult(_ result: CLIImporter.ImportResult, database: CLIDatabase, resolver: CLIResolver) {
        if result.isDuplicate {
            if globals.json {
                let output = CLIOutput(json: true, quiet: globals.quiet)
                output.success(operation: "import", result: CLIOperationResult(
                    id: result.itemId, message: "Already imported '\(result.title)'"
                ))
            } else {
                print("Already imported '\(result.title)' [\(result.itemId.prefix(8))]")
            }
        } else {
            // Apply --collection and --tag flags
            if let collectionName = collection {
                do {
                    let col = try resolver.resolveCollection(collectionName)
                    try database.addItemToCollection(collectionId: col.id, itemId: result.itemId)
                } catch {
                    fputs("Warning: Failed to add to collection '\(collectionName)': \(error.localizedDescription)\n", stderr)
                }
            }
            if let tagName = tag {
                do {
                    let t = try resolver.resolveTag(tagName)
                    try database.addTagToItem(tagId: t.id, itemId: result.itemId)
                } catch {
                    fputs("Warning: Failed to add tag '\(tagName)': \(error.localizedDescription)\n", stderr)
                }
            }
            CLILibraryChangeNotifier.post(operation: "import", message: "Added \"\(result.title)\" from oak", id: result.itemId)

            if globals.json {
                let output = CLIOutput(json: true, quiet: globals.quiet)
                output.success(operation: "import", result: CLIOperationResult(
                    id: result.itemId, message: "Imported '\(result.title)'"
                ))
            } else {
                print("Imported '\(result.title)' [\(result.itemId.prefix(8))]")
            }
        }
    }
}

// MARK: - Search

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search library.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Search query.")
    var query: [String]

    @Option(name: .long, help: "Maximum results (default: 20).")
    var limit: Int = 20

    func run() throws {
        let queryString = query.joined(separator: " ")
        guard !queryString.isEmpty else {
            throw OakError.general("Search query cannot be empty.")
        }

        let database = try CLIDatabase(path: globals.db)
        let results = try database.keywordSearch(query: queryString, limit: limit)
        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.results(operation: "search", items: results, meta: ["count": results.count])
        } else {
            print(CLIFormatters.formatSearchResults(results, query: queryString, mode: "keyword"))
        }
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or set item status.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Item identifier.")
    var item: String

    @Argument(help: "New status value (unread/reading/completed/archived). Omit to show current.")
    var value: String?

    func run() throws {
        let database = try CLIDatabase(path: globals.db)
        let resolver = CLIResolver(db: database)
        let resolved = try resolver.resolveItem(item)

        if let value {
            let statusOption = try resolver.resolveStatus(value)
            try database.setItemStatus(itemId: resolved.id, statusOptionId: statusOption.id)
            CLILibraryChangeNotifier.post(operation: "status.set", message: "Set \"\(resolved.title)\" to \"\(statusOption.name)\"", id: resolved.id)

            if globals.json {
                let output = CLIOutput(json: true, quiet: globals.quiet)
                output.success(operation: "status.set", result: CLIOperationResult(
                    id: resolved.id, message: "Set status of '\(resolved.title)' to '\(statusOption.name)'"
                ))
            } else {
                print("Set status of '\(resolved.title)' to '\(statusOption.name)'")
            }
        } else {
            let status = try database.fetchItemStatus(itemId: resolved.id)

            if globals.json {
                let output = CLIOutput(json: true, quiet: globals.quiet)
                let detail: [String: String?] = [
                    "itemId": resolved.id,
                    "title": resolved.title,
                    "status": status?.name,
                ]
                output.success(operation: "status.show", result: detail)
            } else {
                print(CLIFormatters.formatStatus(item: resolved, status: status))
            }
        }
    }
}

// MARK: - Open (file)

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open file in OakReader (no import).")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "File path to open.")
    var file: String

    func run() throws {
        let resolved = URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw OakError.notFound("file", resolved.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "OakReader", resolved.path]
        try process.run()
        process.waitUntilExit()

        if globals.json {
            let output = CLIOutput(json: true, quiet: globals.quiet)
            output.success(operation: "open", result: CLIOperationResult(
                id: nil, message: "Opened '\(resolved.lastPathComponent)' in OakReader"
            ))
        }
    }
}

// MARK: - Skills

struct Skills: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage agent skills.",
        subcommands: [
            SkillsList.self, SkillsShow.self, SkillsInstall.self,
            SkillsUninstall.self, SkillsCheck.self,
        ],
        defaultSubcommand: SkillsList.self
    )
}

struct SkillsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all skills.")

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        if globals.json {
            let catalog = SkillCommands.loadCatalog()
            let installed = SkillCommands.installedNames()
            let output = CLIOutput(json: true, quiet: globals.quiet)
            let results = catalog.map { skill -> SkillInfo in
                SkillInfo(
                    name: skill.name,
                    description: skill.description,
                    installed: installed.contains(skill.name)
                )
            }
            output.results(operation: "skills.list", items: results, meta: ["count": results.count])
        } else {
            SkillCommands.listSkillsHuman()
        }
    }
}

struct SkillsShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show skill detail.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Skill name.")
    var name: String

    func run() throws {
        if globals.json {
            let catalog = SkillCommands.loadCatalog()
            guard let skill = catalog.first(where: { $0.name == name }) else {
                throw OakError.notFound("skill", name)
            }
            let installed = SkillCommands.installedNames().contains(name)
            let output = CLIOutput(json: true, quiet: globals.quiet)
            let info = SkillDetail(
                name: skill.name,
                description: skill.description,
                installed: installed,
                author: skill.author?.name,
                baseDir: skill.baseDir
            )
            output.success(operation: "skills.show", result: info)
        } else {
            SkillCommands.showSkillHuman(name: name)
        }
    }
}

struct SkillsInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a skill.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Skill name.")
    var name: String

    func run() throws {
        SkillCommands.installSkillAction(name: name, json: globals.json, quiet: globals.quiet)
    }
}

struct SkillsUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Uninstall a skill.")

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Skill name.")
    var name: String

    func run() throws {
        SkillCommands.uninstallSkillAction(name: name, json: globals.json, quiet: globals.quiet)
    }
}

struct SkillsCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Verify installed skill dependencies.")

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        SkillCommands.checkSkillsAction(json: globals.json, quiet: globals.quiet)
    }
}

// MARK: - Skill Codable Models

struct SkillInfo: Encodable {
    let name: String
    let description: String
    let installed: Bool
}

struct SkillDetail: Encodable {
    let name: String
    let description: String
    let installed: Bool
    let author: String?
    let baseDir: String
}

// MARK: - Errors

enum OakError: LocalizedError {
    case notFound(String, String)
    case general(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let type, let input):
            return "No \(type) found matching '\(input)'."
        case .general(let msg):
            return msg
        }
    }
}

// MARK: - Entry Point

Oak.main()
