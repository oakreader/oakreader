import SwiftUI
import OakAI

struct FannedAttachmentStack: View {
    let attachments: [ChatAttachment]

    @State private var isHovered = false
    @State private var appeared = false

    // MARK: - Layout constants

    private let cardWidth: CGFloat = 150
    private let cornerRadius: CGFloat = 8
    private let maxRotation: Double = 3
    private let verticalPeek: CGFloat = 6
    private let horizontalPeek: CGFloat = 5

    private var isExpanded: Bool { isHovered && attachments.count >= 2 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isExpanded {
                expandedLayout
            } else {
                collapsedLayout
            }
        }
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Collapsed (fanned ZStack)

    private var collapsedLayout: some View {
        let count = attachments.count
        return ZStack(alignment: .bottomTrailing) {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                let depth = count - 1 - index
                cardView(attachment)
                    .rotationEffect(rotation(for: depth, total: count), anchor: .bottomTrailing)
                    .offset(
                        x: -CGFloat(depth) * horizontalPeek,
                        y: -CGFloat(depth) * verticalPeek
                    )
                    .zIndex(Double(index))
                    .scaleEffect(appeared ? 1 : 0.8)
                    .opacity(appeared ? 1 : 0)
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.7)
                            .delay(Double(index) * 0.05),
                        value: appeared
                    )
            }
        }
        .onAppear { appeared = true }
    }

    // MARK: - Expanded (vertical list)

    private var expandedLayout: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(attachments) { attachment in
                cardView(attachment)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Single card

    private func cardView(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.type == .textSelection ? "text.quote" : "photo")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if attachment.type == .textSelection, let text = attachment.textContent {
                    Text(text)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if attachment.type == .imageCapture, let data = attachment.imageData,
                          let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 30)
                        .clipped()
                        .cornerRadius(3)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }

    // MARK: - Helpers

    private func rotation(for depth: Int, total: Int) -> Angle {
        guard total > 1 else { return .zero }
        let step = maxRotation / Double(total - 1)
        return .degrees(-step * Double(depth))
    }
}
