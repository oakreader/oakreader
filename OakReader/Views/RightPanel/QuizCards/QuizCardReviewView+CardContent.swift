import SwiftUI
import Textual

// The six per-card-type content renderers for the review session, plus their
// file-local helpers. Split out of QuizCardReviewView.swift for readability;
// behaviour is unchanged. `cardContent` is the dispatch entry point called by
// the session shell, so it is `internal`; everything else stays `private`.
extension QuizCardReviewView {

    // MARK: - Card Content

    @ViewBuilder
    func cardContent(_ card: QuizCard) -> some View {
        switch card.content {
        case .flashcard(let c):
            flashcardContent(c)
        case .cloze(let c):
            clozeContent(c)
        case .occlusion(let c):
            occlusionContent(c)
        }
    }

    private func flashcardContent(_ c: QuizContent.FlashcardContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardMarkdown(text: c.front)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRevealed {
                separator
                    .padding(.vertical, 20)

                Text("Answer")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.bottom, 8)

                CardMarkdown(text: c.back)
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func clozeContent(_ c: QuizContent.ClozeContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isRevealed {
                CardMarkdown(text: revealCloze(c.text))
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CardMarkdown(text: hideCloze(c.text))
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let hint = c.hint {
                    Text("Hint: \(hint)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Occlusion

    private func occlusionContent(_ c: QuizContent.OcclusionContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = NSImage(contentsOfFile: c.imageURL) {
                let nsImage = image
                GeometryReader { geo in
                    let aspectRatio = nsImage.size.width / nsImage.size.height
                    let displayWidth = geo.size.width
                    let displayHeight = displayWidth / aspectRatio

                    ZStack(alignment: .topLeading) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: displayWidth, height: displayHeight)

                        ForEach(c.masks.indices, id: \.self) { idx in
                            let mask = c.masks[idx]
                            let x = (mask["x"] ?? 0) * displayWidth
                            let y = (mask["y"] ?? 0) * displayHeight
                            let w = (mask["w"] ?? 0) * displayWidth
                            let h = (mask["h"] ?? 0) * displayHeight

                            if !isRevealed {
                                occlusionMask(label: idx < c.labels.count ? c.labels[idx] : "", w: w, h: h)
                                    .offset(x: x, y: y)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .frame(width: displayWidth, height: displayHeight)
                }
                .aspectRatio(nsImage.size.width / nsImage.size.height, contentMode: .fit)
                .frame(maxHeight: 300)
            } else {
                Text("Image not found: \(c.imageURL)")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            if isRevealed && !c.labels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(c.labels.indices, id: \.self) { idx in
                        let label = c.labels[idx]
                        if !label.isEmpty {
                            HStack(spacing: 6) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .background(Color.primary.opacity(0.05), in: Circle())
                                CardMarkdown(text: label)
                                    .font(.system(size: 14))
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func occlusionMask(label: String, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.blue.opacity(0.7))
            .frame(width: w, height: h)
            .overlay(
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(2)
            )
    }

    // MARK: - Separator

    var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - Cloze helpers

    private func hideCloze(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\{\{c\d+::([^}]*?)(?:::[^}]*)?\}\}"#,
            with: "`___`",
            options: .regularExpression
        )
    }

    private func revealCloze(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\{\{c\d+::([^}]*?)(?:::[^}]*)?\}\}"#,
            with: "**$1**",
            options: .regularExpression
        )
    }
}
