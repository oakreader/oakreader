import Foundation

/// Loads built-in `Skill` objects from `SKILL.md` + `skill.json` pairs in a directory.
///
/// Only subdirectories containing a `SKILL.md` file with a non-empty body are loaded.
/// The frontmatter fields `title`, `description`, `context-mode`, and `order` map to
/// `Skill` properties; the body text becomes `systemPrompt`. The `skill.json` sidecar
/// provides the SF Symbol icon name.
public enum BuiltInSkillLoader {

    /// Load all built-in skills from a directory, sorted by `order` frontmatter.
    public static func loadSkills(from directory: URL) -> [Skill] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var skills: [(order: Int, skill: Skill)] = []

        for item in contents {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let skillFile = item.appendingPathComponent("SKILL.md")
            guard let data = fm.contents(atPath: skillFile.path),
                  let content = String(data: data, encoding: .utf8),
                  let parsed = FrontmatterParser.parse(content),
                  !parsed.body.isEmpty else { continue }

            let meta = parsed.frontmatter
            let id = meta["name"] ?? item.lastPathComponent
            let name = meta["title"] ?? id
            let description = meta["description"] ?? ""
            let contextMode = ContextMode(rawValue: meta["context-mode"] ?? "") ?? .fullDocument
            let order = Int(meta["order"] ?? "") ?? 99

            // Read icon and version from skill.json sidecar
            let sidecar: SkillManifest? = {
                let jsonURL = item.appendingPathComponent("skill.json")
                guard let jsonData = fm.contents(atPath: jsonURL.path),
                      let manifest = try? JSONDecoder().decode(SkillManifest.self, from: jsonData) else {
                    return nil
                }
                return manifest
            }()

            let icon: String = {
                if case .symbol(let symbol) = sidecar?.icon { return symbol }
                return "sparkles"
            }()

            let skill = Skill(
                id: id,
                name: name,
                description: description,
                systemPrompt: parsed.body,
                icon: icon,
                contextMode: contextMode,
                version: sidecar?.version
            )
            skills.append((order, skill))
        }

        return skills.sorted { $0.order < $1.order }.map(\.skill)
    }
}
