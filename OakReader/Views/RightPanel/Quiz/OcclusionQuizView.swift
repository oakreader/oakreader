import SwiftUI

/// Renders an image occlusion quiz inline in chat — image with colored mask overlays
/// that reveal on tap.
struct OcclusionQuizView: View {
    let content: QuizContent.OcclusionContent

    @State private var revealedMasks: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = NSImage(contentsOfFile: content.imageURL) {
                imageWithMasks(image)
            } else {
                Text("Image not found")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            if !revealedMasks.isEmpty {
                labelsView
            }
        }
    }

    private func imageWithMasks(_ nsImage: NSImage) -> some View {
        GeometryReader { geo in
            let aspectRatio = nsImage.size.width / nsImage.size.height
            let displayWidth = geo.size.width
            let displayHeight = displayWidth / aspectRatio

            ZStack(alignment: .topLeading) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displayWidth, height: displayHeight)

                ForEach(content.masks.indices, id: \.self) { idx in
                    let mask = content.masks[idx]
                    let x = (mask["x"] ?? 0) * displayWidth
                    let y = (mask["y"] ?? 0) * displayHeight
                    let w = (mask["w"] ?? 0) * displayWidth
                    let h = (mask["h"] ?? 0) * displayHeight

                    maskView(idx: idx, w: w, h: h)
                        .offset(x: x, y: y)
                        .opacity(revealedMasks.contains(idx) ? 0 : 1)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.25)) {
                                _ = revealedMasks.insert(idx)
                            }
                        }
                }
            }
            .frame(width: displayWidth, height: displayHeight)
        }
        .aspectRatio(nsImage.size.width / nsImage.size.height, contentMode: .fit)
        .frame(maxHeight: 300)
    }

    private func maskView(idx: Int, w: CGFloat, h: CGFloat) -> some View {
        let label = idx < content.labels.count ? content.labels[idx] : "?"
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.blue.opacity(0.7))
            .frame(width: w, height: h)
            .overlay(
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(2)
            )
    }

    @ViewBuilder
    private var labelsView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(content.labels.indices, id: \.self) { idx in
                let label = content.labels[idx]
                if revealedMasks.contains(idx) && !label.isEmpty {
                    HStack(spacing: 5) {
                        Text("\(idx + 1)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Color.primary.opacity(0.05), in: Circle())
                        CardMarkdown(text: label)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }
}
