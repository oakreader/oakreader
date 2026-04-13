import SwiftUI
import OakReaderAI

struct AttachmentPreviewStrip: View {
    let attachments: [ChatAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.horizontal, ZoteroStyle.Spacing.sm)
            .padding(.vertical, ZoteroStyle.Spacing.xxs)
        }
    }

    private func attachmentChip(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.type == .textSelection ? "text.quote" : "photo")
                .font(.caption2)

            Text(attachment.label)
                .font(.caption)
                .lineLimit(1)

            Button(action: { onRemove(attachment.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.1))
        )
        .foregroundStyle(.primary)
    }
}
