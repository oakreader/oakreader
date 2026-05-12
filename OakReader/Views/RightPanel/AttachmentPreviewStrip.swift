import SwiftUI
import OakAgent

struct AttachmentPreviewStrip: View {
    let attachments: [TurnAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentCard(attachment)
                }
            }
            .padding(.vertical, OakStyle.Spacing.xxs)
        }
    }

    private func attachmentCard(_ attachment: TurnAttachment) -> some View {
        HStack(spacing: 5) {
            // Small thumbnail / icon
            if attachment.type == .imageCapture, let data = attachment.imageData,
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: attachment.type == .textSelection ? "text.quote" : "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
            }

            VStack(alignment: .leading, spacing: 1) {
                if let page = attachment.pageIndex {
                    Text("Page \(page + 1)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(attachment.type == .textSelection ? "text selection" : "region capture")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: { onRemove(attachment.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 1.5, x: 0, y: 0.5)
    }
}
