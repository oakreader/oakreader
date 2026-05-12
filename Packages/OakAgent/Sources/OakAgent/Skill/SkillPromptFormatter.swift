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

        var lines: [String] = []
        lines.append("")
        lines.append("The following skills provide specialized instructions for specific tasks.")
        lines.append("Use the read tool to load a skill's file when the task matches its description.")
        lines.append("")
        lines.append("<available_skills>")

        for skill in visible {
            lines.append("  <skill>")
            lines.append("    <name>\(escapeXML(skill.name))</name>")
            lines.append("    <description>\(escapeXML(skill.description))</description>")
            lines.append("    <location>\(escapeXML(skill.filePath))</location>")
            lines.append("  </skill>")
        }

        lines.append("</available_skills>")
        return lines.joined(separator: "\n")
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
