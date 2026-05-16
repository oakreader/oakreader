import SwiftUI

/// Interactive multiple-choice quiz. Shows green/red feedback on submit.
struct ChoiceQuizView: View {
    let content: QuizContent.ChoiceContent

    @State private var selectedIndex: Int?
    @State private var isSubmitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(content.question)
                .font(.system(size: 13, weight: .medium))

            ForEach(Array(content.choices.enumerated()), id: \.offset) { idx, choice in
                Button {
                    guard !isSubmitted else { return }
                    selectedIndex = idx
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: optionIcon(idx))
                            .foregroundStyle(optionColor(idx))
                            .font(.system(size: 14))

                        Text(choice)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(optionBackground(idx))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(optionBorderColor(idx), lineWidth: selectedIndex == idx ? 1.5 : 0)
                    )
                }
                .buttonStyle(.plain)
            }

            if !isSubmitted && selectedIndex != nil {
                Button("Submit") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSubmitted = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isSubmitted, let explanation = content.explanation {
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func optionIcon(_ idx: Int) -> String {
        if isSubmitted {
            if idx == content.correctIndex { return "checkmark.circle.fill" }
            if idx == selectedIndex { return "xmark.circle.fill" }
        }
        if idx == selectedIndex { return "circle.inset.filled" }
        return "circle"
    }

    private func optionColor(_ idx: Int) -> Color {
        if isSubmitted {
            if idx == content.correctIndex { return .green }
            if idx == selectedIndex { return .red }
        }
        if idx == selectedIndex { return .accentColor }
        return .secondary
    }

    private func optionBackground(_ idx: Int) -> Color {
        if isSubmitted && idx == content.correctIndex {
            return Color.green.opacity(0.1)
        }
        if isSubmitted && idx == selectedIndex && idx != content.correctIndex {
            return Color.red.opacity(0.1)
        }
        return Color.clear
    }

    private func optionBorderColor(_ idx: Int) -> Color {
        if selectedIndex == idx { return optionColor(idx) }
        return .clear
    }
}
