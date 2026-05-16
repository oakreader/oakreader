import SwiftUI

/// Interactive ordering quiz. Users drag items into the correct order.
struct OrderingQuizView: View {
    let content: QuizContent.OrderingContent

    @State private var userOrder: [String] = []
    @State private var isSubmitted = false
    @State private var isCorrect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(content.prompt)
                .font(.system(size: 13, weight: .medium))

            ForEach(Array(userOrder.enumerated()), id: \.offset) { idx, item in
                HStack(spacing: 8) {
                    Text("\(idx + 1).")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)

                    Text(item)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(itemColor(idx))
                        )

                    if !isSubmitted {
                        VStack(spacing: 2) {
                            Button {
                                guard idx > 0 else { return }
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    userOrder.swapAt(idx, idx - 1)
                                }
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == 0)

                            Button {
                                guard idx < userOrder.count - 1 else { return }
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    userOrder.swapAt(idx, idx + 1)
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == userOrder.count - 1)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if !isSubmitted {
                Button("Check Order") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSubmitted = true
                        isCorrect = userOrder == content.items
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(isCorrect ? .green : .red)
                    Text(isCorrect ? "Correct!" : "Not quite. The correct order is shown above.")
                        .font(.system(size: 12))
                        .foregroundStyle(isCorrect ? .green : .red)
                }

                if !isCorrect {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Correct order:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(Array(content.items.enumerated()), id: \.offset) { idx, item in
                            Text("\(idx + 1). \(item)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onAppear {
            if userOrder.isEmpty {
                userOrder = content.items.shuffled()
            }
        }
    }

    private func itemColor(_ idx: Int) -> Color {
        if !isSubmitted { return Color(nsColor: .controlBackgroundColor) }
        if userOrder[idx] == content.items[idx] {
            return Color.green.opacity(0.1)
        }
        return Color.red.opacity(0.1)
    }
}
