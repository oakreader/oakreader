import Foundation

// MARK: - Output Formatting

enum CLIFormatters {

    // MARK: - Items

    static func formatItemList(_ items: [(item: CLIItem, attachments: [CLIAttachment])]) -> String {
        guard !items.isEmpty else {
            return "No items found."
        }

        var lines: [String] = []
        lines.append("\(pad("TITLE", to: 40))  \(pad("AUTHOR", to: 20))  \(pad("TYPE", to: 12))  CITE KEY")
        lines.append(String(repeating: "-", count: 90))

        for entry in items {
            let title = truncate(entry.item.title, to: 38)
            let author = truncate(entry.item.author.isEmpty ? "-" : entry.item.author, to: 18)
            let type = entry.attachments.first?.attachmentType ?? "unknown"
            let citeKey = entry.item.citeKey ?? "-"
            lines.append("\(pad(title, to: 40))  \(pad(author, to: 20))  \(pad(type, to: 12))  \(citeKey)")
        }

        lines.append("")
        lines.append("\(items.count) item\(items.count == 1 ? "" : "s")")
        return lines.joined(separator: "\n")
    }

    static func formatItemDetail(
        item: CLIItem,
        attachments: [CLIAttachment],
        tags: [CLIPropertyOption],
        status: CLIPropertyOption?,
        collections: [CLICollection]
    ) -> String {
        var lines: [String] = []

        lines.append(item.title)
        lines.append(String(repeating: "=", count: min(item.title.count, 60)))
        lines.append("")

        if !item.author.isEmpty {
            lines.append("Author:      \(item.author)")
        }
        if let citeKey = item.citeKey {
            lines.append("Cite Key:    \(citeKey)")
        }
        lines.append("ID:          \(item.id)")
        lines.append("Added:       \(formatDate(item.createdAt))")
        if let lastOpened = item.lastOpenedAt {
            lines.append("Last Opened: \(formatDate(lastOpened))")
        }

        if let status {
            lines.append("Status:      \(status.name)")
        }

        if !tags.isEmpty {
            lines.append("Tags:        \(tags.map(\.name).joined(separator: ", "))")
        }

        if !collections.isEmpty {
            lines.append("Collections: \(collections.map(\.name).joined(separator: ", "))")
        }

        if !attachments.isEmpty {
            lines.append("")
            lines.append("Attachments:")
            for att in attachments {
                let primary = att.isPrimary ? " (primary)" : ""
                let size = formatFileSize(att.fileSize)
                let pages = att.pageCount > 0 ? ", \(att.pageCount) pages" : ""
                lines.append("  - \(att.fileName) [\(att.attachmentType)\(primary), \(size)\(pages)]")
                if let url = att.sourceURL, !url.isEmpty {
                    lines.append("    URL: \(url)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Collections

    static func formatCollectionTree(_ collections: [CLICollection], counts: [String: Int]) -> String {
        guard !collections.isEmpty else {
            return "No collections."
        }

        // Build parent-children map
        var rootCollections: [CLICollection] = []
        var childrenMap: [String: [CLICollection]] = [:]

        for c in collections {
            if let parentId = c.parentId {
                childrenMap[parentId, default: []].append(c)
            } else {
                rootCollections.append(c)
            }
        }

        var lines: [String] = []

        func printTree(_ collection: CLICollection, indent: String, isLast: Bool) {
            let connector = isLast ? "└── " : "├── "
            let count = counts[collection.id] ?? 0
            lines.append("\(indent)\(connector)\(collection.name) (\(count))")

            let children = childrenMap[collection.id] ?? []
            let childIndent = indent + (isLast ? "    " : "│   ")
            for (i, child) in children.enumerated() {
                printTree(child, indent: childIndent, isLast: i == children.count - 1)
            }
        }

        lines.append("Collections:")
        for (i, root) in rootCollections.enumerated() {
            printTree(root, indent: "", isLast: i == rootCollections.count - 1)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Tags

    static func formatTagList(_ tags: [(tag: CLIPropertyOption, count: Int)]) -> String {
        guard !tags.isEmpty else {
            return "No tags."
        }

        var lines: [String] = []
        lines.append("Tags:")
        for entry in tags {
            let colorDot = "#\(entry.tag.colorHex)"
            lines.append("  - \(entry.tag.name) (\(entry.count) items) \(colorDot)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Status

    static func formatStatus(item: CLIItem, status: CLIPropertyOption?) -> String {
        let statusText = status?.name ?? "None"
        return "\(item.title): \(statusText)"
    }

    // MARK: - Stats (for root `oak` command)

    static func formatStats(items: Int, collections: Int, tags: Int) -> String {
        var lines: [String] = []
        lines.append("OakReader Library")
        lines.append(String(repeating: "-", count: 20))
        lines.append("Items:       \(items)")
        lines.append("Collections: \(collections)")
        lines.append("Tags:        \(tags)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func pad(_ string: String, to width: Int) -> String {
        if string.count >= width { return string }
        return string + String(repeating: " ", count: width - string.count)
    }

    static func truncate(_ string: String, to length: Int) -> String {
        if string.count <= length { return string }
        return String(string.prefix(length - 1)) + "…"
    }

    static func formatDate(_ iso8601: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso8601) else { return iso8601 }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024.0
        return String(format: "%.1f GB", gb)
    }
}
