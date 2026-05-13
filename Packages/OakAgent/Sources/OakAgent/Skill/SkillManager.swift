import Foundation

public final class SkillManager: Sendable {
    public static let shared = SkillManager()

    public let builtInSkills: [Skill]

    public func skill(byId id: String) -> Skill? {
        builtInSkills.first { $0.id == id }
    }

    private init() {
        if let skillsDir = Bundle.main.url(forResource: "skills", withExtension: nil) {
            builtInSkills = BuiltInSkillLoader.loadSkills(from: skillsDir)
        } else {
            builtInSkills = []
        }
    }
}
