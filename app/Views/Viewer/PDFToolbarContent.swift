import SwiftUI
import AppKit

/// Per-document chrome row for PDFs — the counterpart to `LiveWebToolbarContent`
/// and `SnapshotToolbarContent`, in the same three zones and the same pill
/// vocabulary, so a PDF tab and a web tab read as the same application.
///
///     web   [‹ › ⟳]  [ address field…………… ]   [🔖]
///     pdf   [⌃ 42/340 ⌄]  [ document title…… ]   [− 140% +]  [✎ ⌄]
///
/// **Why this exists after an overlay was built instead.** The first attempt was
/// a floating pill at the bottom of the reader, on the argument that a page
/// number is continuous state the document already shows, so it did not deserve
/// a permanent row costing ~40pt of reading height. That argument was about
/// screen economy and it ignored the thing that actually matters: a reader looks
/// *up* for chrome, because that is where every other tab in this app keeps it.
/// Bottom-centre, fading or not, is not where anyone looks. See ADR-051.
struct PDFToolbarContent: View {
    let viewModel: DocumentViewModel

    private var state: DocumentState { viewModel.state }
    private var viewer: ViewerViewModel { viewModel.viewer }
    private var pageCount: Int { viewModel.pageCount }

    var body: some View {
        HStack(spacing: 8) {
            pageNavPill
            locationLabel
            if let origin = viewer.returnPage {
                returnChip(origin: origin)
            }
            zoomPill
            MarkupToolbarPill(viewModel: viewModel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Page

    /// Steppers and readout in one pill, the number between them: previous,
    /// where you are, next, reading left to right. Apart, the count sat beside
    /// the zoom pill and read as part of it.
    ///
    /// Vertical chevrons match Go ▸ Previous/Next Page (bound to ↑/↓) and the
    /// context menu. Horizontal chevrons stay reserved for history, which is what
    /// they mean in the web row on a sibling tab.
    private var pageNavPill: some View {
        ToolbarPill {
            HStack(spacing: 2) {
                OakToolButton(systemImage: "chevron.up", tooltip: "Previous Page") {
                    viewer.goToPage(state.currentPageIndex - 1)
                }
                .disabled(state.currentPageIndex <= 0)
                .opacity(state.currentPageIndex <= 0 ? 0.4 : 1)

                pageReadout

                OakToolButton(systemImage: "chevron.down", tooltip: "Next Page") {
                    viewer.goToPage(state.currentPageIndex + 1)
                }
                .disabled(state.currentPageIndex >= pageCount - 1)
                .opacity(state.currentPageIndex >= pageCount - 1 ? 0.4 : 1)
            }
        }
    }

    /// A readout, not a control. Paging happens on the chevrons either side of it
    /// and on ↑/↓; typing a destination is the menu's job (Go ▸ Go to Page…,
    /// ⌥⌘G), which keeps the row's most number-like element from being one you
    /// can fall into by clicking.
    private var pageReadout: some View {
        Text("\(state.currentPageIndex + 1) / \(pageCount)")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 4)
            .accessibilityLabel("Page \(state.currentPageIndex + 1) of \(pageCount)")
    }

    // MARK: - Location

    /// The library title, falling back to the file name only when the item
    /// carries none. A paper's file name is usually its arXiv id or a
    /// download-mangled slug — "2404.12312v1.pdf" tells a reader nothing, while
    /// the catalog already holds the real title. The outline section that used to
    /// trail it is gone: it moved on every scroll, which made the one piece of
    /// chrome that should be stable the most restless thing in the window.
    private var locationLabel: some View {
        Text(documentTitle)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            // A capsule, not the address field's 9pt rounded rect. The web row
            // and this one are never on screen together — they are different
            // tabs — but the title is always beside three capsules, and that is
            // the comparison the eye actually makes. At ~26pt tall, 9pt reads
            // visibly squarer than its neighbours.
            //
            // No focus ring and no hover change: unlike a URL there is nowhere
            // to navigate by typing a title, so this is a plate to sit on rather
            // than a field.
            .background(
                Capsule(style: .continuous)
                    .fill(OakStyle.Colors.hoverBackground)
            )
            .help(documentTitle)
    }

    private var documentTitle: String {
        let title = viewModel.libraryItem?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return viewModel.fileName
    }

    // MARK: - Zoom

    private var zoomPill: some View {
        ToolbarPill {
            HStack(spacing: 2) {
                OakToolButton(systemImage: "minus", tooltip: "Zoom Out (⌘-)") {
                    viewer.zoomOut()
                }
                Text(zoomPercent)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                    .contentShape(Rectangle())
                    .onTapGesture { viewer.zoomToFit() }
                    .help("Zoom to Fit (⌘0)")
                    .accessibilityLabel("Zoom \(zoomPercent). Activate to fit page.")
                OakToolButton(systemImage: "plus", tooltip: "Zoom In (⌘=)") {
                    viewer.zoomIn()
                }
            }
        }
    }

    /// `PDFViewerRepresentable` keeps `state.zoomLevel` in sync with the real
    /// `pdfView.scaleFactor`, so this is live rather than a guess.
    private var zoomPercent: String {
        "\(Int((state.zoomLevel * 100).rounded()))%"
    }

    // MARK: - Return chip

    /// Appears only after a deliberate jump (a chat citation, an outline entry, a
    /// search hit). Naming the destination beats a chevron that cannot say where
    /// it goes — and ordinary page turns no longer file a return point, so this
    /// stays rare enough to be meaningful. See ADR-050.
    private func returnChip(origin: Int) -> some View {
        Button { viewer.jumpBack() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
                Text("Back to p. \(origin + 1)")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(OakStyle.Colors.buttonBackground))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Return to page \(origin + 1), where you jumped from")
        .accessibilityLabel("Back to page \(origin + 1)")
        .fixedSize()
    }
}
