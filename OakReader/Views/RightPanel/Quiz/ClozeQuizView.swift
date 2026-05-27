import SwiftUI

/// Interactive cloze-deletion card. Blanks render as accent pills; tapping one
/// reveals the answer with a soft pop. Chromeless — sits on the deck surface.
struct ClozeQuizView: View {
    let content: QuizContent.ClozeContent
    @State private var revealed: Set<String> = []

    private let accent = QuizStyle.accent(for: .cloze)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            clozeText

            if let hint = content.hint, !hint.isEmpty, revealed.count < clozeIds.count {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 10))
                    Text(hint)
                        .font(QuizStyle.hint)
                }
                .foregroundStyle(.tertiary)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var clozeText: some View {
        let segments = parseClozeSegments(content.text)
        FlowLayout(spacing: 3) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                clozeSegmentView(segment)
            }
        }
    }

    @ViewBuilder
    private func clozeSegmentView(_ segment: ClozeSegment) -> some View {
        switch segment {
        case .text(let str):
            Text(str)
                .font(.system(size: 15))

        case .cloze(let id, let answer):
            if revealed.contains(id) {
                Text(answer)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(0.14)))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Button {
                    withAnimation(QuizStyle.pop) { _ = revealed.insert(id) }
                } label: {
                    Text("？？？")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(minWidth: 46)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .strokeBorder(accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                .background(Capsule().fill(accent.opacity(0.06)))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Parsing

    private var clozeIds: [String] {
        let pattern = #"\{\{(c\d+)::"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = content.text as NSString
        var ids: [String] = []
        regex.enumerateMatches(in: content.text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.range(at: 1).location != NSNotFound else { return }
            ids.append(ns.substring(with: match.range(at: 1)))
        }
        return ids
    }

    private enum ClozeSegment {
        case text(String)
        case cloze(id: String, answer: String)
    }

    private func parseClozeSegments(_ text: String) -> [ClozeSegment] {
        let pattern = #"\{\{(c\d+)::([^}]*?)(?:::[^}]*)?\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }

        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var segments: [ClozeSegment] = []
        var cursor = 0

        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                segments.append(.text(before))
            }
            let id = ns.substring(with: match.range(at: 1))
            let answer = ns.substring(with: match.range(at: 2))
            segments.append(.cloze(id: id, answer: answer))
            cursor = match.range.location + match.range.length
        }

        if cursor < ns.length {
            segments.append(.text(ns.substring(from: cursor)))
        }
        return segments
    }
}
