import Foundation

/// Result of loading skills from one or more directories.
public struct SkillLoadResult: Sendable {
    /// Successfully loaded skills.
    public let skills: [AgentSkill]
    /// Errors encountered during loading, keyed by file path.
    public let errors: [(path: String, message: String)]

    public init(skills: [AgentSkill] = [], errors: [(path: String, message: String)] = []) {
        self.skills = skills
        self.errors = errors
    }
}

/// Discovers and loads `SKILL.md` files from directories following the
/// [Agent Skills](https://agentskills.io) specification.
///
/// Discovery rules:
/// 1. If a directory contains `SKILL.md`, treat it as a skill root (don't recurse further).
/// 2. If a directory contains `skill.json` (without `SKILL.md`), load metadata-only skill.
/// 3. Otherwise, load direct `.md` children as skills.
/// 4. Recurse into non-hidden subdirectories to find `SKILL.md` or `skill.json`.
/// 5. Skip hidden directories and `node_modules`.
public enum SkillLoader {

    /// Load skills from multiple directories (e.g. user-global, project-local).
    public static func loadSkills(from directories: [URL]) -> SkillLoadResult {
        var allSkills: [AgentSkill] = []
        var allErrors: [(path: String, message: String)] = []

        for dir in directories {
            let result = loadFromDirectory(dir)
            allSkills.append(contentsOf: result.skills)
            allErrors.append(contentsOf: result.errors)
        }

        return SkillLoadResult(skills: allSkills, errors: allErrors)
    }

    /// Load skills from a single directory.
    static func loadFromDirectory(_ dir: URL) -> SkillLoadResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return SkillLoadResult()
        }

        // If this directory itself contains SKILL.md, treat as a single skill root
        let skillFile = dir.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: skillFile.path) {
            let result = loadSkillFile(at: skillFile, expectedName: dir.lastPathComponent)
            if let skill = result.skill {
                return SkillLoadResult(skills: [skill])
            } else if let error = result.error {
                return SkillLoadResult(errors: [(skillFile.path, error)])
            }
            return SkillLoadResult()
        }

        // If this directory contains skill.json but no SKILL.md, load metadata-only
        let jsonFile = dir.appendingPathComponent("skill.json")
        if fm.fileExists(atPath: jsonFile.path) {
            let result = loadSkillJsonOnly(at: jsonFile, expectedName: dir.lastPathComponent)
            if let skill = result.skill {
                return SkillLoadResult(skills: [skill])
            } else if let error = result.error {
                return SkillLoadResult(errors: [(jsonFile.path, error)])
            }
            return SkillLoadResult()
        }

        var skills: [AgentSkill] = []
        var errors: [(path: String, message: String)] = []

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

            if itemIsDir.boolValue {
                // Recurse into subdirectory
                let subSkillFile = item.appendingPathComponent("SKILL.md")
                let subJsonFile = item.appendingPathComponent("skill.json")

                if fm.fileExists(atPath: subSkillFile.path) {
                    let result = loadSkillFile(at: subSkillFile, expectedName: item.lastPathComponent)
                    if let skill = result.skill {
                        skills.append(skill)
                    } else if let error = result.error {
                        errors.append((subSkillFile.path, error))
                    }
                } else if fm.fileExists(atPath: subJsonFile.path) {
                    let result = loadSkillJsonOnly(at: subJsonFile, expectedName: item.lastPathComponent)
                    if let skill = result.skill {
                        skills.append(skill)
                    } else if let error = result.error {
                        errors.append((subJsonFile.path, error))
                    }
                } else {
                    // Recurse deeper
                    let sub = loadFromDirectory(item)
                    skills.append(contentsOf: sub.skills)
                    errors.append(contentsOf: sub.errors)
                }
            } else if item.pathExtension.lowercased() == "md" {
                // Root-level .md file — treat as a skill
                let skillName = item.deletingPathExtension().lastPathComponent.lowercased()
                let result = loadSkillFile(at: item, expectedName: skillName)
                if let skill = result.skill {
                    skills.append(skill)
                } else if let error = result.error {
                    errors.append((item.path, error))
                }
            }
        }

        return SkillLoadResult(skills: skills, errors: errors)
    }

    // MARK: - Private

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
        expectedName: String
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
        if !isValidName(name) {
            return (nil, "Skill name '\(name)' must be lowercase alphanumeric with hyphens, max 64 chars")
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
            requirements: manifest.requires
        )

        return (skill, nil)
    }

    private static func loadSkillFile(
        at url: URL,
        expectedName: String
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
        if !isValidName(name) {
            return (nil, "Skill name '\(name)' must be lowercase alphanumeric with hyphens, max 64 chars")
        }

        // Description
        guard let description = meta["description"], !description.isEmpty else {
            return (nil, "Missing required 'description' in frontmatter")
        }
        if description.count > 1024 {
            return (nil, "Description exceeds 1024 characters")
        }

        // Optional flags
        let disableModelInvocation = meta["disable-model-invocation"]?.lowercased() == "true"

        // Try loading skill.json sidecar from the same directory
        let baseDir = url.deletingLastPathComponent()
        let sidecar = loadSidecarManifest(in: baseDir)

        var contextMode: ContextMode? = nil
        if let mode = sidecar?.contextMode {
            contextMode = ContextMode(rawValue: mode)
        }

        let skill = AgentSkill(
            name: name,
            description: description,
            filePath: url.path,
            baseDir: baseDir.path,
            disableModelInvocation: sidecar?.disableModelInvocation ?? disableModelInvocation,
            icon: sidecar?.icon,
            author: sidecar?.author,
            contextMode: contextMode,
            requirements: sidecar?.requires
        )

        return (skill, nil)
    }

    /// Load `skill.json` from a directory if it exists.
    private static func loadSidecarManifest(in directory: URL) -> SkillManifest? {
        let jsonURL = directory.appendingPathComponent("skill.json")
        guard let data = FileManager.default.contents(atPath: jsonURL.path) else {
            return nil
        }
        return try? JSONDecoder().decode(SkillManifest.self, from: data)
    }
}
