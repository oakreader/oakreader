import Foundation

@MainActor
public final class SkillManager {
    public static let shared = SkillManager()

    public nonisolated static let installedDir: URL = {
        #if DEBUG
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader-Dev/skills", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader/skills", isDirectory: true)
        #endif
    }()

    /// Only enabled skills — used by chat, skill picker, and system prompt.
    public private(set) var installedSkills: [Skill] = []

    /// All skills including disabled ones — used by the management UI.
    public private(set) var allInstalledSkills: [Skill] = []

    public func skill(byId id: String) -> Skill? {
        installedSkills.first { $0.id == id }
    }

    public func reload() {
        allInstalledSkills = BuiltInSkillLoader.loadSkills(from: Self.installedDir)
        installedSkills = allInstalledSkills.filter(\.isEnabled)
    }

    private init() {
        reload()
    }
}
