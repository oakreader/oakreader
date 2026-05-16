import SwiftUI

/// Interactive cloze deletion quiz. Blanks are revealed on tap.
struct ClozeQuizView: View {
    let content: QuizContent.ClozeContent
    @State private var revealed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            clozeText
            if let hint = content.hint, revealed.count < clozeIds.count {
                Text("Hint: \(hint)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var clozeText: some View {
        // Parse cloze markers and render as inline text with tappable blanks
        let segments = parseClozeSegments(content.text)
        FlowLayout(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let str):
                    Text(str)
                        .font(.system(size: 13))
                case .cloze(let id, let answer):
                    if revealed.contains(id) {
                        Text(answer)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                revealed.insert(id)
                            }
                        } label: {
                            Text("[      ]")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
            // Text before cloze
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

// MARK: - FlowLayout (simple horizontal wrapping)

/// A simple flow layout that wraps children horizontally.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), offsets)
    }
}
