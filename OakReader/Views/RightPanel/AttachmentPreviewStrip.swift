import SwiftUI
import OakAgent

struct AttachmentPreviewStrip: View {
    let attachments: [TurnAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    AttachmentPill(attachment: attachment, onRemove: onRemove)
                }
            }
            .padding(.vertical, OakStyle.Spacing.xxs)
        }
    }
}

/// A compact "about to send" pill: thumbnail/icon + one concise label + remove.
/// Deliberately lean (one line, single fill, no shadow/border) — the input
/// preview is transient. On hover it reveals a larger preview (enlarged image /
/// full selected text) so the pill stays small without hiding what's attached.
private struct AttachmentPill: View {
    let attachment: TurnAttachment
    let onRemove: (UUID) -> Void

    @State private var hovering = false
    @State private var showPreview = false

    private var image: NSImage? {
        guard attachment.type == .imageCapture, let data = attachment.imageData else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: attachment.type == .textSelection ? "text.quote" : "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Button(action: { onRemove(attachment.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
        )
        .onHover { h in
            hovering = h
            if h {
                // Dwell briefly so a cursor passing over doesn't flash the preview.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if hovering { showPreview = true }
                }
            } else {
                showPreview = false
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .top) { preview }
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360, maxHeight: 360)
                .padding(8)
        } else if attachment.type == .textSelection, let text = attachment.textContent, !text.isEmpty {
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 340, maxHeight: 240)
            .padding(10)
        } else {
            Text(title).font(.system(size: 12)).padding(10)
        }
    }

    /// One concise label: the page when known, else the attachment's own label
    /// (filename for uploads), else a short type word.
    private var title: String {
        if let page = attachment.pageIndex { return "Page \(page + 1)" }
        if !attachment.label.isEmpty { return attachment.label }
        return attachment.type == .textSelection ? "Selection" : "Image"
    }
}
