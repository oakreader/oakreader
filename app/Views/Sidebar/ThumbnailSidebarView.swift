import SwiftUI
import PDFKit

/// Page thumbnails, modelled on Preview's sidebar: one column whatever the width,
/// the page itself with a hairline edge and nothing wrapped around it, its number
/// below, and the current page marked by a soft fill behind it.
struct ThumbnailSidebarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(0..<viewModel.pageCount, id: \.self) { index in
                        ThumbnailItemView(
                            pageIndex: index,
                            isSelected: index == viewModel.state.currentPageIndex,
                            pdfDocument: viewModel.pdfDocument
                        )
                        .id(index)
                        .onTapGesture {
                            // `.reading`, not `.jump`: thumbnails are a
                            // scrubbing surface that stays open, so getting
                            // back is one more click in the same list. A
                            // return point per scrub would bury the one the
                            // reader actually wants (a citation's origin).
                            viewModel.viewer.goToPage(index)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.state.currentPageIndex) { _, newValue in
                withAnimation(OakStyle.Motion.slow) {
                    proxy.scrollTo(newValue, anchor: .center)
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

    /// Pages never grow past this, so a wide sidebar keeps a margin around them
    /// instead of a page the size of the reader.
    private static let maxPageWidth: CGFloat = 200

    private var shouldInvert: Bool {
        switch appearanceMode {
        case "dark": return true
        case "light": return false
        default: return colorScheme == .dark
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            page
                .frame(maxWidth: Self.maxPageWidth)

            Text("\(pageIndex + 1)")
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? OakStyle.Colors.sidebarRowSelection : .clear)
        )
        .contentShape(Rectangle())
        .animation(OakStyle.Motion.fast, value: isSelected)
        // Render the thumbnail once per page, off the main thread, then cache it.
        // `.task(id:)` re-runs only if the page identity actually changes.
        .task(id: pageIndex) {
            if thumbnail != nil { return }
            guard let image = await ThumbnailRenderer.render(pdfDocument, page: pageIndex) else { return }
            thumbnail = image
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(pageIndex + 1)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The sheet itself: the raster with a hairline edge and a short shadow, the
    /// way paper sits on the sidebar. No card around it — the page is the card.
    @ViewBuilder
    private var page: some View {
        Group {
            if let thumbnail {
                let image = Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                if shouldInvert { image.colorInvert() } else { image }
            } else {
                Color(nsColor: .textBackgroundColor)
                    .aspectRatio(1 / 1.294, contentMode: .fit)
            }
        }
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
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
                let image = document.page(at: index)?.thumbnail(maxDimension: 520)
                continuation.resume(returning: image)
            }
        }
    }
}
