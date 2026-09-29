import SwiftUI
import AppKit

/// Per-document chrome row for PDFs — the counterpart to `LiveWebToolbarContent`
/// and `SnapshotToolbarContent`, in the same three zones and the same pill
/// vocabulary, so a PDF tab and a web tab read as the same application.
///
///     web   [‹ › ⟳]  [ address field…………… ]              [🔖]
///     pdf   [⌃ ⌄]    [ file name · section ] [42 / 340]  [− 140% +] [highlight] [capture]
///
/// **Why this exists after an overlay was built instead.** The first attempt
/// was a floating pill at the bottom of the reader, on the argument that a page
/// number is continuous state the document already shows, so it did not deserve
/// a permanent row costing ~40pt of reading height. That argument was about
/// screen economy and it ignored the thing that actually matters: a reader
/// looks *up* for chrome, because that is where every other tab in this app
/// keeps it. Bottom-centre, fading or not, is not where anyone looks. Asked
/// repeatedly where the toolbar was, the honest answer was that it had been
/// argued out of existence rather than designed. See ADR-051.
///
/// Zoom reads `state.zoomLevel`, which `PDFViewerRepresentable` keeps in sync
/// with the real `pdfView.scaleFactor`, so the percentage is live rather than a
/// guess. Page numbers are physical and 1-based, matching every other page
/// affordance in the app.
struct PDFToolbarContent: View {
    let viewModel: DocumentViewModel

    @State private var isEditingPage = false
    @State private var draftPage = ""
    @State private var invalidEntry = false

    @FocusState private var pageFieldFocused: Bool

    @Environment(\.isTabActive) private var isTabActive

    private var state: DocumentState { viewModel.state }
    private var viewer: ViewerViewModel { viewModel.viewer }
    private var pageCount: Int { viewModel.pageCount }

    var body: some View {
        HStack(spacing: 8) {
            pageNavPill
            locationLabel
                .frame(maxWidth: .infinity, alignment: .leading)
            if let origin = viewer.returnPage {
                returnChip(origin: origin)
            }
            pageField
            zoomPill
            actionPill
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onReceive(NotificationCenter.default.publisher(for: .pdfEditPageNumber)) { note in
            guard isTabActive, note.object as AnyObject? === viewModel else { return }
            beginEditingPage()
        }
    }

    // MARK: - Page stepping

    /// Vertical chevrons, matching Go ▸ Previous/Next Page (bound to ↑/↓) and the
    /// PDF context menu. Horizontal chevrons are reserved for history, which is
    /// what they mean in the web row directly above this one on a sibling tab.
    private var pageNavPill: some View {
        ToolbarPill {
            HStack(spacing: 2) {
                OakToolButton(systemImage: "chevron.up", tooltip: "Previous Page") {
                    viewer.goToPage(state.currentPageIndex - 1)
                }
                .disabled(state.currentPageIndex <= 0)
                .opacity(state.currentPageIndex <= 0 ? 0.4 : 1)

                OakToolButton(systemImage: "chevron.down", tooltip: "Next Page") {
                    viewer.goToPage(state.currentPageIndex + 1)
                }
                .disabled(state.currentPageIndex >= pageCount - 1)
                .opacity(state.currentPageIndex >= pageCount - 1 ? 0.4 : 1)
            }
        }
    }

    // MARK: - Location

    /// File name emphasised, containing outline section muted after it — the
    /// same primary/secondary split `URLLabel` gives a web address, so the two
    /// rows carry location the same way. Read-only: unlike a URL there is
    /// nowhere to navigate by typing a file name, and the page field beside it
    /// is the thing you actually retarget.
    private var locationLabel: some View {
        let name = viewModel.fileName
        let section = viewer.currentSectionLabel
        return (
            Text(name).foregroundStyle(.primary)
            + Text(section.map { "  ·  \($0)" } ?? "").foregroundStyle(.secondary)
        )
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(section.map { "\(name) — \($0)" } ?? name)
    }

    // MARK: - Page field

    @ViewBuilder
    private var pageField: some View {
        if isEditingPage {
            HStack(spacing: 3) {
                TextField("", text: $draftPage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .focused($pageFieldFocused)
                    .frame(width: fieldWidth)
                    .onSubmit(commitPage)
                    .onExitCommand(perform: endEditingPage)
                    .onChange(of: draftPage) { _, _ in invalidEntry = false }

                Text("/ \(pageCount)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .fill(OakStyle.Colors.hoverBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .stroke(invalidEntry ? Color.red : Color.accentColor, lineWidth: 1)
            )
            .help(invalidEntry ? "Enter a page number between 1 and \(pageCount)" : "")
        } else {
            Button(action: beginEditingPage) {
                Text("\(state.currentPageIndex + 1) / \(pageCount)")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous).fill(OakStyle.Colors.buttonBackground)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Page \(state.currentPageIndex + 1) of \(pageCount) — click to go to a page (⌥⌘G)")
            .accessibilityLabel("Page \(state.currentPageIndex + 1) of \(pageCount)")
            .accessibilityHint("Activate to enter a page number")
        }
    }

    /// Sized for the document's widest page number so the row doesn't reflow
    /// under the pointer as digits are typed.
    private var fieldWidth: CGFloat {
        CGFloat(max(2, String(pageCount).count)) * 9 + 6
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

    private var zoomPercent: String {
        "\(Int((state.zoomLevel * 100).rounded()))%"
    }

    // MARK: - Actions

    /// Highlight routes through `.selectionApplyHighlight`, the same instrument
    /// the selection popup and ⌃⌘H use, so the coordinator resolves the current
    /// selection exactly once. It arms nothing: with no selection it is a no-op,
    /// which is why it reads as disabled rather than as a mode.
    private var actionPill: some View {
        ToolbarPill {
            HStack(spacing: 2) {
                OakToolButton(systemImage: "highlighter", tooltip: "Highlight Selection (⌃⌘H)") {
                    NotificationCenter.default.post(
                        name: .selectionApplyHighlight, object: viewModel
                    )
                }
                OakToolButton(systemImage: "rectangle.dashed", tooltip: "Capture Area (⇧⌘A)") {
                    state.editorMode = .snapshot
                }
            }
        }
    }

    // MARK: - Return chip

    /// Appears only after a deliberate jump (a chat citation, an outline entry,
    /// a search hit). Naming the destination beats a chevron that cannot say
    /// where it goes — and ordinary page turns no longer file a return point,
    /// so this stays rare enough to be meaningful. See ADR-050.
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

    // MARK: - Page editing

    private func beginEditingPage() {
        draftPage = "\(state.currentPageIndex + 1)"
        invalidEntry = false
        isEditingPage = true
        pageFieldFocused = true
        // The field editor only exists once focus has landed, a runloop turn or
        // two later; selecting in the same hop silently does nothing and the
        // reader's first digit appends to the existing number.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard isEditingPage else { return }
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func commitPage() {
        guard let entered = Int(draftPage.trimmingCharacters(in: .whitespaces)),
              entered >= 1, entered <= pageCount else {
            // Stay editable rather than silently discarding — the red border and
            // the tooltip carry the valid range.
            invalidEntry = true
            pageFieldFocused = true
            return
        }
        viewer.goToPage(entered - 1, kind: .jump)
        endEditingPage()
    }

    private func endEditingPage() {
        isEditingPage = false
        invalidEntry = false
        pageFieldFocused = false
        // Hand the keyboard back to the reader, or ↑/↓ move a caret instead of pages.
        NotificationCenter.default.post(name: .pdfFocusReader, object: viewModel)
    }
}
