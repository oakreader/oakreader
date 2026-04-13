import SwiftUI
import PDFKit

struct WatermarkPreviewView: View {
    let config: WatermarkConfig
    let pdfDocument: PDFDocument?
    let pageIndex: Int

    var body: some View {
        VStack(spacing: 8) {
            Text("Preview")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            if let doc = pdfDocument, let page = doc.page(at: pageIndex) {
                let thumbnail = page.thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox)

                ZStack {
                    // Page thumbnail
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

                    // Watermark overlay
                    watermarkOverlay
                }
                .frame(maxWidth: 300, maxHeight: 400)
                .clipped()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 300, height: 400)
                    .overlay {
                        Text("No page to preview")
                            .foregroundStyle(.secondary)
                    }
            }

            Text("Page \(pageIndex + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var watermarkOverlay: some View {
        GeometryReader { geometry in
            let position = watermarkPosition(in: geometry.size)

            switch config.type {
            case .text(let text):
                Text(text)
                    .font(.system(size: config.fontSize * 0.3))
                    .foregroundStyle(Color(nsColor: config.color).opacity(config.opacity))
                    .rotationEffect(.degrees(config.rotation))
                    .position(position)

            case .image(let data):
                if let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80 * config.scale, height: 80 * config.scale)
                        .opacity(config.opacity)
                        .rotationEffect(.degrees(config.rotation))
                        .position(position)
                }
            }
        }
    }

    private func watermarkPosition(in size: CGSize) -> CGPoint {
        let margin: CGFloat = 20
        switch config.position {
        case .center:
            return CGPoint(x: size.width / 2, y: size.height / 2)
        case .topLeft:
            return CGPoint(x: margin + 40, y: margin + 20)
        case .topCenter:
            return CGPoint(x: size.width / 2, y: margin + 20)
        case .topRight:
            return CGPoint(x: size.width - margin - 40, y: margin + 20)
        case .bottomLeft:
            return CGPoint(x: margin + 40, y: size.height - margin - 20)
        case .bottomCenter:
            return CGPoint(x: size.width / 2, y: size.height - margin - 20)
        case .bottomRight:
            return CGPoint(x: size.width - margin - 40, y: size.height - margin - 20)
        }
    }
}
