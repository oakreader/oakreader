import Foundation

/// Turns a document's notes (the `annotations`-table rows the Notes panel shows)
/// into portable Markdown. Two shapes, mirroring flomo / Obsidian export:
///   • **one file per note** in a folder (`exportToFolder`) — local images are
///     copied into an `images/` subfolder and their links rewritten relative, so
///     the folder is self-contained and movable;
///   • **one combined Markdown** (`combinedMarkdown`) — every note in a single
///     file, `---`-separated; local image links are left as absolute `file://`
///     paths (a single file can't bundle its images).
///
/// Notes live in SQLite, not on disk, so there is no "note folder" to link to —
/// export is the way to get them onto the filesystem.
enum NoteExporter {

    // MARK: Combined (single file)

    static func combinedMarkdown(records: [AnnotationRecord], title: String) -> String {
        var out = "# \(title) — Notes\n\n"
        out += "*\(records.count) note\(records.count == 1 ? "" : "s")*\n"
        for record in records {
            out += "\n---\n\n"
            out += noteSection(record: record)
        }
        return out + "\n"
    }

    // MARK: Folder (one file per note)

    /// Write one `.md` per note into a freshly-created `<title> Notes` folder under
    /// `parentDir`, copying any local images into `images/`. Returns the folder URL.
    @discardableResult
    static func exportToFolder(records: [AnnotationRecord], title: String, parentDir: URL) throws -> URL {
        let fm = FileManager.default

        var folder = parentDir.appendingPathComponent(safeFileName("\(title) Notes"), isDirectory: true)
        var suffix = 1
        while fm.fileExists(atPath: folder.path) {
            folder = parentDir.appendingPathComponent("\(safeFileName("\(title) Notes")) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let imagesDir = folder.appendingPathComponent("images", isDirectory: true)
        var imageCache: [String: String] = [:]
        var usedNames = Set<String>()

        for (idx, record) in records.enumerated() {
            let fileName = uniqueFileName(for: record, index: idx, used: &usedNames)
            let body = rewriteImages(in: record.comment ?? "", copyingTo: imagesDir, cache: &imageCache, fm: fm)
            let content = noteSection(record: record, body: body)
            try content.write(to: folder.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        }
        return folder
    }

    // MARK: One note → markdown

    /// A single note as a `## timestamp` section: optional quoted source (for an
    /// anchored note) as a blockquote, then the note body verbatim (tags, image
    /// links and note links preserved). `body` overrides `record.comment` so the
    /// folder export can pass an image-rewritten copy.
    static func noteSection(record: AnnotationRecord, body overrideBody: String? = nil) -> String {
        var s = ""
        let ts = NoteTime.absolute(record.createdAt)
        s += ts.isEmpty ? "## Note\n\n" : "## \(ts)\n\n"

        if record.positionKind != "memo",
           let quote = record.text?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            s += quote.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }.joined(separator: "\n")
            s += "\n\n"
        }

        let body = (overrideBody ?? record.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { s += body + "\n" }
        return s
    }

    // MARK: Filenames

    private static func uniqueFileName(for record: AnnotationRecord, index: Int, used: inout Set<String>) -> String {
        let ts = NoteTime.absolute(record.createdAt).replacingOccurrences(of: ":", with: "")
        let slug = slugify(NoteTags.preview(NoteComposerBox.splitBody(record.comment ?? "").text))
        var base = [ts, slug].filter { !$0.isEmpty }.joined(separator: " - ")
        if base.isEmpty { base = "note-\(index + 1)" }
        base = safeFileName(base)

        var name = "\(base).md"
        var n = 1
        while used.contains(name) {
            name = "\(base) \(n).md"
            n += 1
        }
        used.insert(name)
        return name
    }

    private static func safeFileName(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }

    private static func slugify(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").prefix(40))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Image copying (folder export)

    /// Rewrite every `![alt](url)` whose `url` is a local file: copy the file into
    /// `imagesDir` and point the link at `images/<name>`. Remote (`http`) images and
    /// missing files are left untouched. `cache` dedupes repeated sources across notes.
    private static func rewriteImages(
        in body: String, copyingTo imagesDir: URL, cache: inout [String: String], fm: FileManager
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(!\[[^\]]*\]\()([^)]+)(\))"#) else { return body }
        let ns = body as NSString
        let matches = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return body }

        var result = ""
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let prefix = ns.substring(with: m.range(at: 1))
            let urlStr = ns.substring(with: m.range(at: 2))
            let suffix = ns.substring(with: m.range(at: 3))
            if let destName = copiedImageName(urlStr, to: imagesDir, cache: &cache, fm: fm) {
                result += "\(prefix)images/\(destName)\(suffix)"
            } else {
                result += "\(prefix)\(urlStr)\(suffix)"
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func copiedImageName(
        _ urlStr: String, to dir: URL, cache: inout [String: String], fm: FileManager
    ) -> String? {
        if let cached = cache[urlStr] { return cached }

        let srcPath: String
        if let u = URL(string: urlStr), u.isFileURL { srcPath = u.path }
        else if urlStr.hasPrefix("/") { srcPath = urlStr }
        else { return nil }  // remote image — leave the link as-is
        guard fm.fileExists(atPath: srcPath) else { return nil }

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = (srcPath as NSString).lastPathComponent
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            var dest = dir.appendingPathComponent(base)
            var i = 1
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)")
                i += 1
            }
            try fm.copyItem(atPath: srcPath, toPath: dest.path)
            cache[urlStr] = dest.lastPathComponent
            return dest.lastPathComponent
        } catch {
            return nil
        }
    }
}
