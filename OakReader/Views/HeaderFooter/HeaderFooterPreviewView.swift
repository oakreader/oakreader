import SwiftUI
import PDFKit

struct HeaderFooterPreviewView: View {
    let config: HeaderFooterConfig
    let pdfDocument: PDFDocument?
    let pageIndex: Int
    let totalPages: Int

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

                    // Header/footer overlay
                    GeometryReader { geometry in
                        let marginScale = geometry.size.width / 612.0

                        VStack {
                            // Header
                            HStack {
                                Text(resolvedHeader(.left))
                                    .font(.system(size: max(6, config.fontSize * marginScale * 0.5)))
                                Spacer()
                                Text(resolvedHeader(.center))
                                    .font(.system(size: max(6, config.fontSize * marginScale * 0.5)))
                                Spacer()
                                Text(resolvedHeader(.right))
                                    .font(.system(size: max(6, config.fontSize * marginScale * 0.5)))
                            }
                            .foregroundStyle(Color(nsColor: config.color))
                            .padding(.horizontal, config.margins.left * marginScale * 0.5)
                            .padding(.top, config.margins.top * marginScale * 0.5)

                            Spacer()

                            // Footer
                            HStack {
                                Text(resolvedFooter(.left))
                                    .font(.system(size: max(6, config.fontSize * marginScale * 0.5)))
                                Spacer()
                                Text(resolvedFooter(.center))
                                    .font(.system(size: max(6, config.fontSize * marginScale * 0.5)))
                                Spacer()
                                Text(resolvedFooter(.right))
                                    .font(.system(size: max(6, config.fontSize * marginScale * 0.5)))
                            }
                            .foregroundStyle(Color(nsColor: config.color))
                            .padding(.horizontal, config.margins.left * marginScale * 0.5)
                            .padding(.bottom, config.margins.bottom * marginScale * 0.5)
                        }
                    }
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

    private enum Position { case left, center, right }

    private func resolvedHeader(_ pos: Position) -> String {
        let template: String
        switch pos {
        case .left: template = config.headerLeft
        case .center: template = config.headerCenter
        case .right: template = config.headerRight
        }
        return config.resolvedText(template, pageIndex: pageIndex, totalPages: totalPages)
    }

    private func resolvedFooter(_ pos: Position) -> String {
        let template: String
        switch pos {
        case .left: template = config.footerLeft
        case .center: template = config.footerCenter
        case .right: template = config.footerRight
        }
        return config.resolvedText(template, pageIndex: pageIndex, totalPages: totalPages)
    }
}
