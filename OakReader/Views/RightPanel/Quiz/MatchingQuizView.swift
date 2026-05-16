import SwiftUI

/// Interactive matching quiz. Users tap items in left and right columns to create pairs.
struct MatchingQuizView: View {
    let content: QuizContent.MatchingContent

    @State private var shuffledRight: [String] = []
    @State private var selectedLeft: Int?
    @State private var selectedRight: Int?
    @State private var matchedPairs: Set<Int> = []  // indices into content.pairs
    @State private var wrongPair: (left: Int, right: Int)?
    @State private var isComplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap to match:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                // Left column
                VStack(spacing: 6) {
                    ForEach(Array(content.pairs.enumerated()), id: \.offset) { idx, pair in
                        leftItem(pair.left, index: idx)
                    }
                }

                // Right column
                VStack(spacing: 6) {
                    ForEach(Array(shuffledRight.enumerated()), id: \.offset) { idx, text in
                        rightItem(text, index: idx)
                    }
                }
            }

            if isComplete {
                Text("All matched!")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .onAppear {
            if shuffledRight.isEmpty {
                shuffledRight = content.pairs.map(\.right).shuffled()
            }
        }
    }

    @ViewBuilder
    private func leftItem(_ text: String, index: Int) -> some View {
        let isMatched = matchedPairs.contains(index)
        let isSelected = selectedLeft == index
        let isWrong = wrongPair?.left == index

        Button {
            guard !isMatched else { return }
            selectedLeft = index
            tryMatch()
        } label: {
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(itemBackground(isMatched: isMatched, isSelected: isSelected, isWrong: isWrong))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(itemBorder(isMatched: isMatched, isSelected: isSelected), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .opacity(isMatched ? 0.5 : 1)
    }

    @ViewBuilder
    private func rightItem(_ text: String, index: Int) -> some View {
        let correctPairIndex = content.pairs.firstIndex { $0.right == text }
        let isMatched = correctPairIndex.map { matchedPairs.contains($0) } ?? false
        let isSelected = selectedRight == index
        let isWrong = wrongPair?.right == index

        Button {
            guard !isMatched else { return }
            selectedRight = index
            tryMatch()
        } label: {
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(itemBackground(isMatched: isMatched, isSelected: isSelected, isWrong: isWrong))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(itemBorder(isMatched: isMatched, isSelected: isSelected), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .opacity(isMatched ? 0.5 : 1)
    }

    private func tryMatch() {
        guard let left = selectedLeft, let right = selectedRight else { return }

        let rightText = shuffledRight[right]
        if content.pairs[left].right == rightText {
            // Correct match
            withAnimation(.easeInOut(duration: 0.2)) {
                matchedPairs.insert(left)
                selectedLeft = nil
                selectedRight = nil
                wrongPair = nil
                if matchedPairs.count == content.pairs.count {
                    isComplete = true
                }
            }
        } else {
            // Wrong match — flash red
            wrongPair = (left: left, right: right)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation {
                    wrongPair = nil
                    selectedLeft = nil
                    selectedRight = nil
                }
            }
        }
    }

    private func itemBackground(isMatched: Bool, isSelected: Bool, isWrong: Bool) -> Color {
        if isWrong { return Color.red.opacity(0.15) }
        if isMatched { return Color.green.opacity(0.1) }
        if isSelected { return Color.accentColor.opacity(0.1) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private func itemBorder(isMatched: Bool, isSelected: Bool) -> Color {
        if isMatched { return Color.green.opacity(0.3) }
        if isSelected { return Color.accentColor.opacity(0.5) }
        return Color.secondary.opacity(0.2)
    }
}
