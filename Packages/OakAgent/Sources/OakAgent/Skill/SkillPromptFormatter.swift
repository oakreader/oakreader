import Foundation

/// Formats agent skills as XML for injection into the LLM system prompt.
///
/// Follows the [Agent Skills](https://agentskills.io) prompt format so the LLM
/// can discover skills and read their full instructions via the `read` tool.
public enum SkillPromptFormatter {

    /// Format skills as an XML block for the system prompt.
    ///
    /// Only includes skills where `disableModelInvocation` is `false`.
    /// Returns an empty string if no skills are available for model invocation.
    public static func formatForPrompt(_ skills: [AgentSkill]) -> String {
        let visible = skills.filter { !$0.disableModelInvocation }
        guard !visible.isEmpty else { return "" }

        let header = """


        The following skills provide specialized instructions for specific tasks.
        Use the read tool to load a skill's file when the task matches its description.
        When a skill file references a relative path, resolve it against the skill's directory (the parent of its SKILL.md) and use that absolute path in tool commands.

        <available_skills>
        """

        let entries = visible.map { skill in
            """
              <skill>
                <name>\(escapeXML(skill.name))</name>
                <description>\(escapeXML(skill.description))</description>
                <location>\(escapeXML(skill.filePath))</location>
              </skill>
            """
        }

        return ([header] + entries + ["</available_skills>"]).joined(separator: "\n")
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
