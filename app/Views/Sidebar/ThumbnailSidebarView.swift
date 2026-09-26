import SwiftUI
import PDFKit

struct ThumbnailSidebarView: View {
    let viewModel: DocumentViewModel

    @State private var draggedPageIndex: Int?

    private let padding: CGFloat = 8
    private let spacing: CGFloat = 8
    private let minThumbWidth: CGFloat = 90

    var body: some View {
        GeometryReader { geo in
            let columns = [GridItem(.adaptive(minimum: minThumbWidth), spacing: spacing)]

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(0..<viewModel.pageCount, id: \.self) { index in
                            ThumbnailItemView(
                                pageIndex: index,
                                isSelected: index == viewModel.state.currentPageIndex,
                                pdfDocument: viewModel.pdfDocument
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

    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @Environment(\.colorScheme) private var colorScheme

    /// The rasterized page, rendered ONCE off the main thread and cached here.
    /// Rendering must never happen in `body`: a full `CGContextDrawPDFPage` raster
    /// inside the body getter re-fired on every window SwiftUI transaction (e.g. a
    /// composer keystroke/animation re-running `NSHostingView.layout()`), re-rastering
    /// every visible page on the main thread → a sustained beachball. Caching makes
    /// body re-evaluation free.
    @State private var thumbnail: NSImage?

    private let borderWidth: CGFloat = 3
    private let cardPadding: CGFloat = 4

    private var shouldInvert: Bool {
        switch appearanceMode {
        case "dark": return true
        case "light": return false
        default: return colorScheme == .dark
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Thumbnail image — fills available width, aspect ratio preserved.
            // Reads the cached raster; rendering is done in `.task` below, not here.
            if let thumbnail {
                let imageView = Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                if shouldInvert {
                    imageView.colorInvert()
                } else {
                    imageView
                }
            } else {
                Color.secondary.opacity(0.1)
                    .aspectRatio(1 / 1.294, contentMode: .fit)
            }

            // Page number at bottom
            Text("\(pageIndex + 1)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
        }
        // Render the thumbnail once per page, off the main thread, then cache it.
        // `.task(id:)` re-runs only if the page identity actually changes.
        .task(id: pageIndex) {
            if thumbnail != nil { return }
            guard let image = await ThumbnailRenderer.render(pdfDocument, page: pageIndex) else { return }
            thumbnail = image
        }
        .padding([.horizontal, .top], cardPadding)
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
        .contextMenu {
            Button { } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            Button { } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            Divider()
            Button(role: .destructive) { } label: {
                Label("Delete Page", systemImage: "trash")
            }
        }
    }
}

/// Renders PDF page thumbnails off the main thread, one at a time.
///
/// PDF rasterization (`CGContextDrawPDFPage`) is expensive; doing it in a SwiftUI
/// `body` getter re-rastered every visible page on every window transaction and
/// beachballed the main thread (confirmed by a `sample`: `ThumbnailItemView.body`
/// → `PDFPage.thumbnail` → `CGContextDrawPDFPageWithOptions`). This moves the work
/// to a single serial background queue — PDFKit pages aren't safe to render
/// concurrently — so the main thread only ever assigns the finished image.
private enum ThumbnailRenderer {
    private static let queue = DispatchQueue(label: "com.oakreader.pdf-thumbnail", qos: .userInitiated)

    static func render(_ document: PDFDocument?, page index: Int) async -> NSImage? {
        guard let document else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            queue.async {
                let image = document.page(at: index)?.thumbnail(maxDimension: 240)
                continuation.resume(returning: image)
            }
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
