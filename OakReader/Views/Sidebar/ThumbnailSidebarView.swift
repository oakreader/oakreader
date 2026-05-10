import SwiftUI
import PDFKit

struct ThumbnailSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var draggedPageIndex: Int?

    private let padding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let thumbWidth = max(60, geo.size.width - padding * 2)
            let thumbHeight = thumbWidth * 1.294 // US Letter aspect ratio

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(0..<viewModel.pageCount, id: \.self) { index in
                            ThumbnailItemView(
                                pageIndex: index,
                                isSelected: index == viewModel.state.currentPageIndex,
                                pdfDocument: viewModel.pdfDocument,
                                thumbWidth: thumbWidth,
                                thumbHeight: thumbHeight
                            )
                            .id(index)
                            .onTapGesture {
                                viewModel.viewer.goToPage(index)
                            }
                            .onDrag {
                                draggedPageIndex = index
                                return NSItemProvider(object: "\(index)" as NSString)
                            }
                            .onDrop(of: [.text], delegate: ThumbnailDropDelegate(
                                targetIndex: index,
                                draggedIndex: $draggedPageIndex,
                                viewModel: viewModel
                            ))
                        }
                    }
                    .padding(padding)
                }
                .onChange(of: viewModel.state.currentPageIndex) { _, newValue in
                    withAnimation {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct ThumbnailItemView: View {
    let pageIndex: Int
    let isSelected: Bool
    let pdfDocument: PDFDocument?
    let thumbWidth: CGFloat
    let thumbHeight: CGFloat

    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @Environment(\.colorScheme) private var colorScheme

    private let borderWidth: CGFloat = 3
    private let cardPadding: CGFloat = 6

    private var shouldInvert: Bool {
        switch appearanceMode {
        case "dark": return true
        case "light": return false
        default: return colorScheme == .dark
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Thumbnail image
            ZStack {
                if let page = pdfDocument?.page(at: pageIndex) {
                    let renderSize = max(thumbWidth, thumbHeight)
                    let thumbnail = page.thumbnail(maxDimension: renderSize)
                    let imageView = Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: thumbWidth - cardPadding * 2 - borderWidth * 2,
                               maxHeight: thumbHeight - cardPadding * 2 - borderWidth * 2 - 28)
                    if shouldInvert {
                        imageView.colorInvert()
                    } else {
                        imageView
                    }
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: thumbWidth - cardPadding * 2 - borderWidth * 2,
                               height: thumbHeight - cardPadding * 2 - borderWidth * 2 - 28)
                }
            }
            .padding(.horizontal, cardPadding)
            .padding(.top, cardPadding)
            .padding(.bottom, 4)

            // Page number at bottom
            Text("\(pageIndex + 1)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.primary.opacity(0.25) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? borderWidth : 1
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Rotate Right") {}
            Button("Rotate Left") {}
            Divider()
            Button("Delete Page", role: .destructive) {}
        }
    }
}

private struct ThumbnailDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedIndex: Int?
    let viewModel: DocumentViewModel

    func dropEntered(info: DropInfo) {}

    func performDrop(info: DropInfo) -> Bool {
        return false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
