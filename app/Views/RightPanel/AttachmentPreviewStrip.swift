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
            // Size the popover to the image's own aspect ratio so it hugs the
            // picture instead of floating it in a fixed square with empty space.
            let size = previewSize(for: image)
            Image(nsImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .padding(8)
        } else if attachment.type == .textSelection, let text = attachment.textContent, !text.isEmpty {
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    // Fixed width + vertical fixedSize makes the text WRAP and grow
                    // downward, instead of laying out as one ideal-width line that the
                    // popover then clamps and truncates.
                    .frame(width: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
            .frame(maxHeight: 260)
        } else {
            Text(title).font(.system(size: 12)).padding(10)
        }
    }

    /// The preview's display size: the image's real aspect ratio scaled to fit a
    /// bounding box (so a wide screenshot becomes a wide, short popover — never a
    /// tall box with empty space).
    private func previewSize(for image: NSImage) -> CGSize {
        let maxW: CGFloat = 460, maxH: CGFloat = 360
        let s = image.size
        guard s.width > 0, s.height > 0 else { return CGSize(width: 240, height: 180) }
        let scale = min(maxW / s.width, maxH / s.height)
        return CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
    }

    /// One concise label: the page when known, else the attachment's own label
    /// (filename for uploads), else a short type word.
    private var title: String {
        if let page = attachment.pageIndex { return "Page \(page + 1)" }
        if !attachment.label.isEmpty { return attachment.label }
        return attachment.type == .textSelection ? "Selection" : "Image"
    }
}
