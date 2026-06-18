import SwiftUI
import OakAgent

struct FannedAttachmentStack: View {
    let attachments: [TurnAttachment]

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
                AttachmentCard(attachment: attachment, cardWidth: cardWidth, cornerRadius: cornerRadius)
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
                AttachmentCard(attachment: attachment, cardWidth: cardWidth, cornerRadius: cornerRadius)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Helpers

    private func rotation(for depth: Int, total: Int) -> Angle {
        guard total > 1 else { return .zero }
        let step = maxRotation / Double(total - 1)
        return .degrees(-step * Double(depth))
    }
}

/// One attachment chip in a user message. Image captures lead with an aspect
/// thumbnail and are clickable to preview full-size (Dia's `AttachmentCellView`
/// pattern — image-forward + a clickable control); text selections show the
/// quoted text. Previously the image was a 30pt strip squeezed next to an icon,
/// which made screenshots look like illegible text and offered nothing to click.
private struct AttachmentCard: View {
    let attachment: TurnAttachment
    let cardWidth: CGFloat
    let cornerRadius: CGFloat

    @State private var showPreview = false

    private var image: NSImage? {
        guard attachment.type == .imageCapture, let data = attachment.imageData else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        content
            .frame(width: cardWidth)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color(nsColor: .controlBackgroundColor)))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Button { showPreview = true } label: { imageCard(image) }
                .buttonStyle(.plain)
                .help("Click to view full size")
                .popover(isPresented: $showPreview, arrowEdge: .leading) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 640, maxHeight: 640)
                        .padding(8)
                }
        } else {
            infoCard
        }
    }

    /// Image-forward: the thumbnail is the card, with the label as a small caption.
    private func imageCard(_ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: cardWidth, height: 92)
                .clipped()
            Text(attachment.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
        }
    }

    /// Text-selection (or an image whose data didn't load): icon + label + quote.
    private var infoCard: some View {
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
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
