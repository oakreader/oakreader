import Foundation

/// Result of loading skills from one or more directories.
public struct SkillLoadResult: Sendable {
    /// Successfully loaded skills.
    public let skills: [AgentSkill]
    /// Errors and advisories encountered during loading, keyed by file path.
    public let errors: [(path: String, message: String)]

    public init(skills: [AgentSkill] = [], errors: [(path: String, message: String)] = []) {
        self.skills = skills
        self.errors = errors
    }
}

/// Discovers and loads ``AgentSkill`` objects (agent-invoked, lazily read) from `SKILL.md`
/// files, following the [Agent Skills](https://agentskills.io) specification. For the
/// user-toggled chat-mode counterpart, see ``BuiltInSkillLoader`` / ``Skill``.
///
/// Discovery rules:
/// 1. If a directory contains `SKILL.md`, treat it as a skill root (don't recurse further).
/// 2. If a directory contains `skill.json` (without `SKILL.md`), load metadata-only skill.
/// 3. Otherwise, load direct `.md` children as skills — only at the top level of each
///    scanned directory, never inside recursed subdirectories (subdirs must use `SKILL.md`).
/// 4. Recurse into non-hidden subdirectories to find `SKILL.md` or `skill.json`.
/// 5. Skip hidden directories, `node_modules`, and anything matched by a
///    `.gitignore` / `.ignore` / `.fdignore` file in the scanned tree.
public enum SkillLoader {

    private static let ignoreFileNames = [".gitignore", ".ignore", ".fdignore"]

    /// Load skills from multiple directories (e.g. user-global, project-local).
    ///
    /// Duplicates are resolved first-wins: the first directory that defines a given
    /// skill name (or points at the same real file via symlink) takes precedence;
    /// later duplicates are dropped and recorded as advisories.
    ///
    /// - Parameter source: Origin label applied to every skill found under `directories`.
    public static func loadSkills(from directories: [URL], source: SkillSource = .path) -> SkillLoadResult {
        var skills: [AgentSkill] = []
        var errors: [(path: String, message: String)] = []
        var seenNames = Set<String>()
        var seenRealPaths = Set<String>()

        for dir in directories {
            let result = loadFromDirectory(dir, source: source)
            errors.append(contentsOf: result.errors)

            for skill in result.skills {
                let realPath = URL(fileURLWithPath: skill.filePath).resolvingSymlinksInPath().path

                // Same underlying file reached via a symlink — drop silently.
                if seenRealPaths.contains(realPath) { continue }

                if seenNames.contains(skill.name) {
                    errors.append((
                        skill.filePath,
                        "Skill name '\(skill.name)' collides with an already-loaded skill; ignoring duplicate"
                    ))
                    continue
                }

                seenNames.insert(skill.name)
                seenRealPaths.insert(realPath)
                skills.append(skill)
            }
        }

        return SkillLoadResult(skills: skills, errors: errors)
    }

    /// Load skills from a single directory.
    ///
    /// - Parameters:
    ///   - source: Origin label applied to skills found here.
    ///   - includeLooseMarkdown: When `true`, root-level `.md` files in this directory
    ///     are treated as skills. Recursion sets this to `false` so nested directories
    ///     only contribute via `SKILL.md` (avoids picking up README/notes files).
    ///   - matcher: Accumulated ignore rules from ancestor directories. Value semantics
    ///     mean children inherit parent rules without polluting siblings.
    ///   - rootDir: The top of the scan, used to compute root-relative paths for ignore
    ///     matching. Defaults to `dir` on the first (non-recursive) call.
    static func loadFromDirectory(
        _ dir: URL,
        source: SkillSource,
        includeLooseMarkdown: Bool = true,
        matcher: GitignoreMatcher = GitignoreMatcher(),
        rootDir: URL? = nil
    ) -> SkillLoadResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return SkillLoadResult()
        }

        let root = rootDir ?? dir
        var ig = matcher
        addIgnoreRules(&ig, dir: dir, root: root)

        // If this directory itself contains SKILL.md, treat as a single skill root.
        let skillFile = dir.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: skillFile.path) {
            return makeResult(loadSkillFile(at: skillFile, expectedName: dir.lastPathComponent, source: source), path: skillFile.path)
        }

        // If this directory contains skill.json but no SKILL.md, load metadata-only.
        let jsonFile = dir.appendingPathComponent("skill.json")
        if fm.fileExists(atPath: jsonFile.path) {
            return makeResult(loadSkillJsonOnly(at: jsonFile, expectedName: dir.lastPathComponent, source: source), path: jsonFile.path)
        }

        var skills: [AgentSkill] = []
        var errors: [(path: String, message: String)] = []

        func record(_ result: (skill: AgentSkill?, error: String?), path: String) {
            if let skill = result.skill { skills.append(skill) }
            if let error = result.error { errors.append((path, error)) }
        }

        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SkillLoadResult()
        }

        for item in contents {
            let name = item.lastPathComponent

            // Skip node_modules
            if name == "node_modules" { continue }

            var itemIsDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)

            // Honour .gitignore / .ignore rules — directories tested with a trailing slash.
            let relPath = relativePosixPath(of: item, from: root)
            if !relPath.isEmpty, ig.isIgnored(itemIsDir.boolValue ? relPath + "/" : relPath) {
                continue
            }

            if itemIsDir.boolValue {
                // Recurse into subdirectory
                let subSkillFile = item.appendingPathComponent("SKILL.md")
                let subJsonFile = item.appendingPathComponent("skill.json")

                if fm.fileExists(atPath: subSkillFile.path) {
                    record(loadSkillFile(at: subSkillFile, expectedName: item.lastPathComponent, source: source), path: subSkillFile.path)
                } else if fm.fileExists(atPath: subJsonFile.path) {
                    record(loadSkillJsonOnly(at: subJsonFile, expectedName: item.lastPathComponent, source: source), path: subJsonFile.path)
                } else {
                    // Recurse deeper — loose .md files below the top level are not skills.
                    let sub = loadFromDirectory(item, source: source, includeLooseMarkdown: false, matcher: ig, rootDir: root)
                    skills.append(contentsOf: sub.skills)
                    errors.append(contentsOf: sub.errors)
                }
            } else if includeLooseMarkdown, item.pathExtension.lowercased() == "md" {
                // Top-level .md file — treat as a skill.
                let skillName = item.deletingPathExtension().lastPathComponent.lowercased()
                record(loadSkillFile(at: item, expectedName: skillName, source: source), path: item.path)
            }
        }

        return SkillLoadResult(skills: skills, errors: errors)
    }

    // MARK: - Ignore rules

    /// Read any ignore files in `dir` and add their rules, anchored at `dir`'s path
    /// relative to the scan root.
    private static func addIgnoreRules(_ ig: inout GitignoreMatcher, dir: URL, root: URL) {
        let prefix = relativePosixPath(of: dir, from: root)
        let prefixWithSlash = prefix.isEmpty ? "" : prefix + "/"

        for name in ignoreFileNames {
            let url = dir.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path),
                  let content = String(data: data, encoding: .utf8) else { continue }
            ig.add(lines: content.components(separatedBy: .newlines), prefix: prefixWithSlash)
        }
    }

    /// Path of `url` relative to `root` as a posix-style string (empty if `url == root`
    /// or `url` is not under `root`).
    private static func relativePosixPath(of url: URL, from root: URL) -> String {
        let rootComps = root.standardizedFileURL.pathComponents
        let urlComps = url.standardizedFileURL.pathComponents
        guard urlComps.count >= rootComps.count,
              Array(urlComps.prefix(rootComps.count)) == rootComps else {
            return ""
        }
        return urlComps.dropFirst(rootComps.count).joined(separator: "/")
    }

    // MARK: - Loading

    /// Wrap a single load result (skill and/or advisory) into a `SkillLoadResult`.
    private static func makeResult(_ result: (skill: AgentSkill?, error: String?), path: String) -> SkillLoadResult {
        var skills: [AgentSkill] = []
        var errors: [(path: String, message: String)] = []
        if let skill = result.skill { skills.append(skill) }
        if let error = result.error { errors.append((path, error)) }
        return SkillLoadResult(skills: skills, errors: errors)
    }

    /// Validates that a name contains only lowercase letters, digits, and hyphens,
    /// with no leading/trailing hyphens and no double hyphens.
    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard !name.hasPrefix("-"), !name.hasSuffix("-") else { return false }
        guard !name.contains("--") else { return false }
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Load a `skill.json`-only skill (no SKILL.md present).
    private static func loadSkillJsonOnly(
        at url: URL,
        expectedName: String,
        source: SkillSource
    ) -> (skill: AgentSkill?, error: String?) {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return (nil, "Cannot read skill.json")
        }

        let manifest: SkillManifest
        do {
            manifest = try JSONDecoder().decode(SkillManifest.self, from: data)
        } catch {
            return (nil, "Invalid skill.json: \(error.localizedDescription)")
        }

        let name = manifest.name ?? expectedName

        // An invalid name is a non-fatal advisory: the skill still loads (matches upstream).
        var advisory: String?
        if !isValidName(name) {
            advisory = "Skill name '\(name)' should be lowercase alphanumeric with hyphens (max 64 chars)"
        }

        let description = manifest.description ?? ""
        let disableModelInvocation = manifest.disableModelInvocation ?? false

        var contextMode: ContextMode? = nil
        if let mode = manifest.contextMode {
            contextMode = ContextMode(rawValue: mode)
        }

        let skill = AgentSkill(
            name: name,
            description: description,
            filePath: url.path,
            baseDir: url.deletingLastPathComponent().path,
            disableModelInvocation: disableModelInvocation,
            icon: manifest.icon,
            author: manifest.author,
            contextMode: contextMode,
            requirements: manifest.requires,
            version: manifest.version,
            isEnabled: manifest.enabled ?? true,
            source: source
        )

        return (skill, advisory)
    }

    private static func loadSkillFile(
        at url: URL,
        expectedName: String,
        source: SkillSource
    ) -> (skill: AgentSkill?, error: String?) {
        guard let data = FileManager.default.contents(atPath: url.path),
              let content = String(data: data, encoding: .utf8) else {
            return (nil, "Cannot read file")
        }

        guard let parsed = FrontmatterParser.parse(content) else {
            return (nil, "Missing or invalid YAML frontmatter")
        }

        let meta = parsed.frontmatter

        // Name
        let name = meta["name"] ?? expectedName

        // Description is the only hard requirement (Agent Skills spec / upstream pi).
        guard let description = meta["description"], !description.isEmpty else {
            return (nil, "Missing required 'description' in frontmatter")
        }

        // Name validity and over-length descriptions are non-fatal advisories — the
        // skill still loads so it remains discoverable, matching upstream behaviour.
        var advisory: String?
        if !isValidName(name) {
            advisory = "Skill name '\(name)' should be lowercase alphanumeric with hyphens (max 64 chars)"
        } else if description.count > 1024 {
            advisory = "Description exceeds 1024 characters"
        }

        // Try loading skill.json sidecar from the same directory
        let baseDir = url.deletingLastPathComponent()
        let sidecar = SkillManifest.sidecar(in: baseDir)

        var contextMode: ContextMode? = nil
        if let mode = sidecar?.contextMode {
            contextMode = ContextMode(rawValue: mode)
        }

        let skill = AgentSkill(
            name: name,
            description: description,
            filePath: url.path,
            baseDir: baseDir.path,
            disableModelInvocation: sidecar?.disableModelInvocation ?? (meta["disable-model-invocation"]?.lowercased() == "true"),
            icon: sidecar?.icon,
            author: sidecar?.author,
            contextMode: contextMode,
            requirements: sidecar?.requires,
            version: sidecar?.version,
            isEnabled: sidecar?.enabled ?? true,
            source: source
        )

        return (skill, advisory)
    }
}
