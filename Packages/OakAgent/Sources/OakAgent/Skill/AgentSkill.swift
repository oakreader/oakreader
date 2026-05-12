import Foundation

/// A file-based agent skill discovered from `SKILL.md` files.
///
/// Follows the [Agent Skills](https://agentskills.io) standard:
/// skills are defined by Markdown files with YAML frontmatter and loaded lazily
/// by the LLM via the `read` tool when a task matches the skill's description.
public struct AgentSkill: Sendable, Identifiable {
    public var id: String { name }

    /// Lowercase, hyphen-separated name (e.g. "swift-lint"). Must match parent directory name.
    public let name: String

    /// Short description shown in the system prompt skill listing.
    public let description: String

    /// Absolute path to the `SKILL.md` file.
    public let filePath: String

    /// Parent directory of the skill file (for resolving relative paths).
    public let baseDir: String

    /// When `true`, the skill is only invoked via explicit `/skill:name` — the LLM
    /// will not see it in the available skills listing.
    public let disableModelInvocation: Bool

    public init(
        name: String,
        description: String,
        filePath: String,
        baseDir: String,
        disableModelInvocation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.filePath = filePath
        self.baseDir = baseDir
        self.disableModelInvocation = disableModelInvocation
    }
}
