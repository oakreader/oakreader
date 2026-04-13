import SwiftUI
import PDFKit

struct PageThumbnailCell: View {
    let pageIndex: Int
    let pdfDocument: PDFDocument?
    let isSelected: Bool
    let rotation: Int

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail
                if let page = pdfDocument?.page(at: pageIndex) {
                    let size = CGSize(width: 140, height: 180)
                    let thumbnail = page.thumbnail(of: size, for: .mediaBox)
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 140, maxHeight: 180)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 140, height: 180)
                }

                // Selection indicator
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .frame(maxWidth: 140, maxHeight: 180)
                }

                // Rotation badge
                if rotation != 0 {
                    Text("\(rotation >= 0 ? "+" : "")\(rotation)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                        .padding(4)
                }
            }

            // Page number
            Text("Page \(pageIndex + 1)")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .fontWeight(isSelected ? .semibold : .regular)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
    }
}
