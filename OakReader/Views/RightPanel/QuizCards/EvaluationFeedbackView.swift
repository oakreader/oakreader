import SwiftUI

/// Displays evaluation result: correct/incorrect icon, correct answer, and optional explanation.
struct EvaluationFeedbackView: View {
    let result: EvaluationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status indicator
            HStack(spacing: 8) {
                Image(systemName: result.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(result.isCorrect ? .green : .red)

                Text(result.isCorrect ? "Correct" : "Incorrect")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(result.isCorrect ? .green : .red)
            }

            // Correct answer (always shown)
            if !result.isCorrect {
                HStack(alignment: .top, spacing: 6) {
                    Text("Answer:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(result.correctAnswer)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // AI explanation (detailed mode)
            if let explanation = result.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(result.isCorrect ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
        )
    }
}
