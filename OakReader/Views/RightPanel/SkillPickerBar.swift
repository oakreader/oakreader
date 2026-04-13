import SwiftUI
import OakReaderAI

struct SkillPickerBar: View {
    @Binding var selectedSkill: Skill?

    private let skills = SkillManager.shared.builtInSkills

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(skills) { skill in
                    skillChip(skill)
                }
            }
            .padding(.horizontal, ZoteroStyle.Spacing.sm)
            .padding(.vertical, ZoteroStyle.Spacing.xs)
        }
    }

    private func skillChip(_ skill: Skill) -> some View {
        let isSelected = selectedSkill?.id == skill.id

        return Button(action: {
            if isSelected {
                selectedSkill = nil
            } else {
                selectedSkill = skill
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: skill.icon)
                    .font(.system(size: 12))
                Text(skill.name)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(skill.description)
    }
}
