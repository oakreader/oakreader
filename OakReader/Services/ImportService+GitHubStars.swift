import Foundation

extension ImportService {

    struct GitHubStarsSyncResult {
        var imported: Int = 0
        var skipped: Int = 0
        var total: Int = 0
    }

    /// Sync GitHub starred repos using the provided Personal Access Token.
    /// Paginates until no more results. Deduplicates by source/sourceKey.
    /// - Parameter onProgress: Called after each page with the running result. Awaited before fetching the next page.
    func syncGitHubStars(token: String, onProgress: ((GitHubStarsSyncResult) async -> Void)? = nil) async throws -> GitHubStarsSyncResult {
        var result = GitHubStarsSyncResult()
        var page = 1

        while true {
            let starredPage = try await GitHubStarsAPIClient.fetchStarred(token: token, page: page)
            guard !starredPage.repos.isEmpty else { break }

            for repo in starredPage.repos {
                result.total += 1
                let sourceKey = "\(repo.id)"

                if store.findItem(bySource: "github_stars", sourceKey: sourceKey) != nil {
                    result.skipped += 1
                    continue
                }

                importGitHubRepo(repo: repo)
                result.imported += 1
            }

            await onProgress?(result)

            guard starredPage.hasNextPage else { break }
            page += 1
        }

        return result
    }

    /// Re-sync existing GitHub Stars: re-fetch repo metadata + README, regenerate embed.html.
    /// - `forceAll`: true = update every item; false = only items missing readme.md (backfill).
    func resyncGitHubStars(token: String, forceAll: Bool) async -> GitHubStarsSyncResult {
        let allItems = store.items.filter { $0.source == "github_stars" }
        var result = GitHubStarsSyncResult()

        // Filter to items that need work
        let itemsToProcess: [LibraryItem]
        if forceAll {
            itemsToProcess = allItems
        } else {
            // Backfill: only items without readme.md on disk
            itemsToProcess = allItems.filter { item in
                guard let att = item.primaryAttachment else { return false }
                let readmePath = CatalogDatabase.attachmentDirectory(
                    itemStorageKey: item.storageKey,
                    attachmentStorageKey: att.storageKey
                ).appendingPathComponent("readme.md").path
                return !FileManager.default.fileExists(atPath: readmePath)
            }
        }

        result.total = itemsToProcess.count
        guard !itemsToProcess.isEmpty else { return result }

        Log.info(Log.importer, "GitHub Stars \(forceAll ? "re-sync" : "backfill"): \(itemsToProcess.count) items to process")

        for item in itemsToProcess {
            guard !Task.isCancelled else { break }
            guard let att = item.primaryAttachment else {
                result.skipped += 1
                continue
            }

            let fullName = item.title  // stored as "owner/repo"
            let parts = fullName.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else {
                result.skipped += 1
                continue
            }
            let owner = String(parts[0])
            let repo = String(parts[1])

            // Fetch repo metadata + README in parallel
            async let repoInfo = GitHubStarsAPIClient.fetchRepo(token: token, owner: owner, repo: repo)
            async let readme = GitHubStarsAPIClient.fetchReadme(token: token, owner: owner, repo: repo)
            let (fetchedRepo, fetchedReadme) = await (repoInfo, readme)

            guard let repoData = fetchedRepo else {
                result.skipped += 1
                continue
            }

            let attDir = CatalogDatabase.attachmentDirectory(
                itemStorageKey: item.storageKey,
                attachmentStorageKey: att.storageKey
            )

            // Regenerate embed.html with fresh data
            let embedHTML = Self.generateGitHubRepoEmbedHTML(repo: repoData, readme: fetchedReadme)
            try? embedHTML.write(
                to: attDir.appendingPathComponent("embed.html"),
                atomically: true, encoding: .utf8
            )

            // Write readme.md
            if let fetchedReadme, !fetchedReadme.isEmpty {
                try? fetchedReadme.write(
                    to: attDir.appendingPathComponent("readme.md"),
                    atomically: true, encoding: .utf8
                )
            }

            result.imported += 1
        }

        return result
    }

    /// Import a single GitHub starred repo as an embed item.
    /// README is NOT fetched here — use resyncGitHubStars to backfill READMEs.
    private func importGitHubRepo(repo: GitHubStarsAPIClient.StarredRepo) {
        let repoURL = URL(string: repo.htmlUrl)!
        let sourceKey = "\(repo.id)"

        let metadata = MediaMetadata(
            title: repo.fullName,
            author: repo.owner.login,
            sourceURL: repoURL,
            duration: nil,
            thumbnailURL: URL(string: repo.owner.avatarUrl),
            publishedAt: nil,
            description: repo.description,
            embedType: "link"
        )

        let docId = UUID()
        let attId = UUID()
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)

            // Write metadata.json
            let metadataURL = CatalogDatabase.attachmentMetadataURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
            let encoded = try JSONEncoder().encode(metadata)
            try encoded.write(to: metadataURL, options: .atomic)

            // Generate GitHub repo embed page (without README — will be backfilled by re-sync)
            let embedHTML = Self.generateGitHubRepoEmbedHTML(repo: repo)
            let embedHTMLURL = attDir.appendingPathComponent("embed.html")
            try embedHTML.write(to: embedHTMLURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error(Log.importer, "Failed to import GitHub star \(repo.fullName): \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return
        }

        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: repo.fullName,
            author: repo.owner.login,
            lastOpenedAt: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now,
            source: "github_stars",
            sourceKey: sourceKey
        )

        let attRecord = AttachmentRecord(
            id: attId.uuidString,
            itemId: docId.uuidString,
            storageKey: attStorageKey,
            fileName: "metadata.json",
            contentType: ContentType.video.rawValue,
            linkMode: LinkMode.linkedURL.rawValue,
            sourceURL: repoURL.absoluteString,
            fileSize: 0,
            pageCount: 0,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        guard let item = store.insertItem(itemRecord, attachment: attRecord) else {
            try? FileManager.default.removeItem(at: docDir)
            return
        }

        // Auto-create CSL reference
        var csl = CSLItem(type: "software")
        csl.title = repo.fullName
        csl.author = [CSLName(family: repo.owner.login, given: nil)]
        csl.URL = repoURL.absoluteString
        try? referenceService.saveMetadata(csl, forItemId: docId.uuidString)
        store.invalidate()

        // Semantic index
        if let service = semanticIndexService {
            Task {
                await service.indexItem(
                    itemId: docId.uuidString,
                    contentType: ContentType.video.rawValue,
                    storageKey: itemStorageKey,
                    attStorageKey: attStorageKey,
                    fileName: "metadata.json"
                )
            }
        }
    }

    // MARK: - GitHub Repo Embed HTML

    /// Generate a styled HTML page for a GitHub repository — compact header + rendered README.
    static func generateGitHubRepoEmbedHTML(repo: GitHubStarsAPIClient.StarredRepo, readme: String? = nil) -> String {
        let fullName = escapeHTML(repo.fullName)
        let owner = escapeHTML(repo.owner.login)
        let description = escapeHTML(repo.description ?? "No description provided.")
        let repoURL = escapeHTML(repo.htmlUrl)
        let avatarURL = escapeHTML(repo.owner.avatarUrl)
        let language = repo.language.map(escapeHTML) ?? ""
        let stars = formatStarCount(repo.stargazersCount)
        let topics = (repo.topics ?? []).prefix(5)

        let languageDot: String
        if !language.isEmpty {
            let color = languageColor(for: repo.language ?? "")
            languageDot = """
            <span class="language">
              <span class="lang-dot" style="background:\(color)"></span>
              \(language)
            </span>
            """
        } else {
            languageDot = ""
        }

        let topicPills = topics.map { topic in
            "<span class=\"topic\">\(escapeHTML(topic))</span>"
        }.joined(separator: "\n              ")

        // Render README markdown to HTML using cmark-gfm (no JS, works offline).
        // Strip <script> and <iframe> tags to prevent XSS from malicious READMEs.
        let readmeSection: String
        if let readme, !readme.isEmpty {
            var renderedHTML = MarkdownRenderer.renderHTML(readme)
            renderedHTML = Self.stripDangerousTags(renderedHTML)
            readmeSection = "<article class=\"markdown-body\">\(renderedHTML)</article>"
        } else {
            readmeSection = "<p class=\"no-readme\">No README available.</p>"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            padding: 32px;
          }
          /* Light theme (default) */
          body { background: #ffffff; color: #1f2328; }
          .card { background: #f6f8fa; border: 1px solid #d1d9e0; }
          .repo-name { color: #0969da; }
          .owner { color: #656d76; }
          .gh-logo { fill: #1f2328; }
          .description { color: #656d76; }
          .meta { color: #656d76; }
          .topic { background: #ddf4ff; color: #0969da; }
          .source { border-top-color: #d1d9e0; color: #656d76; }
          .source a { color: #0969da; }
          .stars svg { fill: #e3b341; }
          .no-readme { color: #656d76; }

          /* Dark theme */
          @media (prefers-color-scheme: dark) {
            body { background: #0d1117; color: #e6edf3; }
            .card { background: #161b22; border-color: #30363d; }
            .repo-name { color: #58a6ff; }
            .owner { color: #8b949e; }
            .gh-logo { fill: #e6edf3; }
            .description { color: #8b949e; }
            .meta { color: #8b949e; }
            .topic { background: rgba(56,139,253,0.15); color: #58a6ff; }
            .source { border-top-color: #30363d; color: #8b949e; }
            .source a { color: #58a6ff; }
            .no-readme { color: #8b949e; }
          }

          .card {
            border-radius: 12px;
            padding: 20px 24px;
            max-width: 800px;
            margin: 0 auto 24px;
          }
          .header { display: flex; align-items: center; gap: 12px; margin-bottom: 12px; }
          .avatar { width: 36px; height: 36px; border-radius: 50%; flex-shrink: 0; }
          .repo-info { flex: 1; min-width: 0; }
          .repo-name { font-weight: 700; font-size: 16px; text-decoration: none; }
          .owner { font-size: 13px; }
          .gh-logo { width: 22px; height: 22px; flex-shrink: 0; }
          .description { font-size: 14px; line-height: 1.5; margin-bottom: 12px; }
          .meta { display: flex; align-items: center; gap: 16px; font-size: 13px; margin-bottom: 8px; }
          .language { display: flex; align-items: center; gap: 4px; }
          .lang-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
          .stars { display: flex; align-items: center; gap: 4px; }
          .topics { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px; }
          .topic { font-size: 12px; padding: 2px 8px; border-radius: 12px; }
          .source { font-size: 13px; padding-top: 10px; }
          .source a { text-decoration: none; }
          .no-readme { max-width: 800px; margin: 0 auto; font-style: italic; }

          /* GitHub-style markdown rendering */
          .markdown-body {
            max-width: 800px;
            margin: 0 auto;
            font-size: 15px;
            line-height: 1.6;
            word-wrap: break-word;
          }
          .markdown-body h1 { font-size: 2em; font-weight: 600; padding-bottom: .3em; border-bottom: 1px solid; margin: 24px 0 16px; }
          .markdown-body h2 { font-size: 1.5em; font-weight: 600; padding-bottom: .3em; border-bottom: 1px solid; margin: 24px 0 16px; }
          .markdown-body h3 { font-size: 1.25em; font-weight: 600; margin: 24px 0 16px; }
          .markdown-body h4 { font-size: 1em; font-weight: 600; margin: 24px 0 16px; }
          .markdown-body h1, .markdown-body h2 { border-bottom-color: var(--border); }
          .markdown-body p { margin: 0 0 16px; }
          .markdown-body a { color: var(--link); text-decoration: none; }
          .markdown-body a:hover { text-decoration: underline; }
          .markdown-body img { max-width: 100%; border-radius: 6px; }
          .markdown-body code {
            padding: 0.2em 0.4em; font-size: 85%; border-radius: 6px;
            font-family: "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
            background: var(--code-bg);
          }
          .markdown-body pre {
            padding: 16px; overflow: auto; border-radius: 6px; margin: 0 0 16px;
            background: var(--pre-bg); border: 1px solid var(--border);
          }
          .markdown-body pre code { background: none; padding: 0; font-size: 85%; }
          .markdown-body blockquote {
            padding: 0 1em; border-left: .25em solid var(--border); margin: 0 0 16px;
          }
          .markdown-body blockquote > :first-child { margin-top: 0; }
          .markdown-body blockquote > :last-child { margin-bottom: 0; }
          .markdown-body ul, .markdown-body ol { padding-left: 2em; margin: 0 0 16px; }
          .markdown-body li + li { margin-top: .25em; }
          .markdown-body table { border-spacing: 0; border-collapse: collapse; margin: 0 0 16px; width: auto; overflow: auto; }
          .markdown-body th, .markdown-body td { padding: 6px 13px; border: 1px solid var(--border); }
          .markdown-body th { font-weight: 600; background: var(--code-bg); }
          .markdown-body hr { height: .25em; padding: 0; margin: 24px 0; border: 0; background: var(--border); }
          .markdown-body details { margin: 0 0 16px; }
          .markdown-body summary { cursor: pointer; font-weight: 600; }

          /* Light theme variables */
          :root {
            --border: #d1d9e0; --link: #0969da;
            --code-bg: rgba(175,184,193,0.2); --pre-bg: #f6f8fa;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --border: #30363d; --link: #58a6ff;
              --code-bg: rgba(110,118,129,0.4); --pre-bg: #161b22;
            }
            .markdown-body blockquote { color: #8b949e; }
          }
        </style>
        </head>
        <body>
        <div class="card">
          <div class="header">
            <img class="avatar" src="\(avatarURL)" alt="\(owner)">
            <div class="repo-info">
              <a class="repo-name" href="\(repoURL)">\(fullName)</a>
              <div class="owner">\(owner)</div>
            </div>
            <svg class="gh-logo" viewBox="0 0 16 16">
              <path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38
              0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15
              .08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82
              -.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51
              1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82
              1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42
              3.58-8 8-8Z"/>
            </svg>
          </div>
          <div class="description">\(description)</div>
          <div class="meta">
            \(languageDot)
            <span class="stars">
              <svg width="14" height="14" viewBox="0 0 16 16">
                <path d="M8 .25a.75.75 0 0 1 .673.418l1.882 3.815 4.21.612a.75.75 0 0 1
                .416 1.279l-3.046 2.97.719 4.192a.751.751 0 0 1-1.088.791L8 12.347l-3.766
                1.98a.75.75 0 0 1-1.088-.79l.72-4.194L.818 6.374a.75.75 0 0 1
                .416-1.28l4.21-.611L7.327.668A.75.75 0 0 1 8 .25Z"/>
              </svg>
              \(stars)
            </span>
          </div>
          \(topics.isEmpty ? "" : "<div class=\"topics\">\n              \(topicPills)\n          </div>")
          <div class="source">
            <a href="\(repoURL)">View on GitHub</a>
          </div>
        </div>
        \(readmeSection)
        </body>
        </html>
        """
    }

    /// Remove dangerous HTML tags (script, iframe, object, embed, form) from rendered HTML.
    private static func stripDangerousTags(_ html: String) -> String {
        let patterns = [
            #"<script\b[^>]*>[\s\S]*?</script>"#,
            #"<script\b[^>]*/>"#,
            #"<iframe\b[^>]*>[\s\S]*?</iframe>"#,
            #"<iframe\b[^>]*/>"#,
            #"<object\b[^>]*>[\s\S]*?</object>"#,
            #"<embed\b[^>]*/?>"#,
            #"<form\b[^>]*>[\s\S]*?</form>"#,
            #"\bon\w+\s*=\s*"[^"]*""#,   // onclick="..." etc.
            #"\bon\w+\s*=\s*'[^']*'"#,   // onclick='...' etc.
        ]
        var result = html
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ""
                )
            }
        }
        return result
    }

    private static func formatStarCount(_ count: Int) -> String {
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return String(format: "%.1fk", k)
        }
        return "\(count)"
    }

    private static func languageColor(for language: String) -> String {
        switch language.lowercased() {
        case "swift": return "#F05138"
        case "python": return "#3572A5"
        case "javascript": return "#F1E05A"
        case "typescript": return "#3178C6"
        case "rust": return "#DEA584"
        case "go": return "#00ADD8"
        case "java": return "#B07219"
        case "c++", "cpp": return "#F34B7D"
        case "c": return "#555555"
        case "c#": return "#178600"
        case "ruby": return "#701516"
        case "kotlin": return "#A97BFF"
        case "dart": return "#00B4AB"
        case "lua": return "#000080"
        case "shell": return "#89E051"
        case "html": return "#E34C26"
        case "css": return "#563D7C"
        case "php": return "#4F5D95"
        case "scala": return "#C22D40"
        case "zig": return "#EC915C"
        default: return "#8B949E"
        }
    }
}
