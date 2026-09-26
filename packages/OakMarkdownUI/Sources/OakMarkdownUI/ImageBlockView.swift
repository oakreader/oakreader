import SwiftUI
import AppKit

/// A standalone markdown image (`![alt](url)` on its own block) rendered as a real
/// SwiftUI `Image` so it can carry a hover-revealed fullscreen button. Inline images
/// inside a paragraph still render as text attachments (see MarkdownAttributedBuilder);
/// only block images get their own view.
///
/// Local images load via the host's `OakMarkdownImage.urlResolver` (e.g. `oak://image/…`)
/// or a `file://`/absolute path — the same resolution the inline renderer uses. Remote or
/// unresolvable images fall back to prose so the alt text still shows.
struct ImageBlockView: View {
    let url: String
    let alt: String
    let theme: MarkdownTheme

    @State private var isHovering = false
    @State private var showFullscreen = false

    /// Cap the inline width the same way the inline attachment renderer does, and never
    /// upscale a small image past its natural size.
    private static let maxWidth: CGFloat = 260

    var body: some View {
        if let image = Self.load(url) {
            let width = min(image.size.width, Self.maxWidth)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: theme.codeBlockBorder), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) { expandButton }
                .onHover { isHovering = $0 }
                .sheet(isPresented: $showFullscreen) {
                    ImageFullscreenView(image: image, alt: alt)
                }
        } else {
            ProseBlockView(
                attributed: MarkdownAttributedBuilder.attributedString(
                    for: "![\(alt)](\(url))", theme: theme),
                selectable: true,
                animatesAppendedText: false,
                onOpenURL: nil,
                linkPreview: nil
            )
        }
    }

    private var expandButton: some View {
        Button { showFullscreen = true } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: theme.textColor))
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: theme.codeBlockBorder), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Open image in full screen")
        // Explicit label so SF Symbol a11y lookups don't walk the localized
        // description table on every hover re-render (see SF-symbol-a11y-hang note).
        .accessibilityLabel("Expand image")
        .padding(6)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    /// Resolve a markdown image destination to an `NSImage`, mirroring the inline
    /// renderer's resolution order: host resolver → `file://` → absolute path. Remote
    /// URLs return nil (the renderer never blocks on the network).
    static func load(_ dest: String) -> NSImage? {
        if let resolved = OakMarkdownImage.urlResolver?(dest), let img = NSImage(contentsOf: resolved) {
            return img
        }
        if let url = URL(string: dest), url.isFileURL, let img = NSImage(contentsOf: url) {
            return img
        }
        if dest.hasPrefix("/"), let img = NSImage(contentsOfFile: dest) {
            return img
        }
        return nil
    }
}

/// Full-window image presentation: the image scaled to fit the sheet, with a Done
/// button. Esc dismisses.
private struct ImageFullscreenView: View {
    let image: NSImage
    let alt: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !alt.isEmpty {
                    Text(alt).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 460, idealHeight: 680)
    }
}
