import Foundation

@MainActor
public final class SkillManager {
    public static let shared = SkillManager()

    public nonisolated static let installedDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader/agent/skills", isDirectory: true)
    }()

    public private(set) var installedSkills: [Skill] = []

    public func skill(byId id: String) -> Skill? {
        installedSkills.first { $0.id == id }
    }

    public func reload() {
        installedSkills = BuiltInSkillLoader.loadSkills(from: Self.installedDir)
    }

    private init() {
        reload()
    }
}
