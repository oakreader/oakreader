import SwiftUI
import AppKit

/// Floating "where am I" control for the PDF reader: the current page, the
/// outline section containing it, page steppers, and a one-shot return to
/// wherever the last jump came from.
///
/// **Why an overlay and not a toolbar row.** The live-web tab carries a
/// persistent chrome row because a URL is genuinely global state — you can
/// navigate anywhere from it, and it is the only place the address is legible.
/// A PDF's location is neither: it changes continuously as you scroll, and the
/// page in front of you already tells you most of it. A permanent row would
/// cost ~40pt of reading height on *every* PDF session (the web row is 28pt of
/// button plus 6pt padding either side) to remove one category of layout change
/// between tabs — a real, continuous tax for a cosmetic win. The earlier PDF
/// toolbar was deleted for the same reason and this deliberately does not
/// revive it; see `DocumentToolbarView`.
///
/// So the consistency here is of *principle*, not of pixels: chrome shows
/// location, tools live where the hand already is (the selection popup, menus,
/// keys). Highlight and underline stay out for that reason — not because a
/// button would arm a mode (the repo routes those straight through shared
/// instruments) but because a second entry point costs attention and buys
/// nothing over a popup that appears on the selection itself.
///
/// Page numbers throughout are **physical and 1-based**, matching every other
/// page affordance in the app. PDFs that carry printed labels ("iv", or a
/// printed 42 on physical page 50) are not reconciled here.
struct PageLocationOverlay: View {
    let viewModel: DocumentViewModel

    /// Seconds the pill lingers after the page stops changing.
    private static let lingerAfterPageChange: TimeInterval = 1.6

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draftPage = ""
    @State private var invalidEntry = false
    @State private var revealToken = 0
    @State private var isRevealed = false

    @FocusState private var fieldFocused: Bool

    /// Every tab's `ContentView` stays alive at opacity 0 (see `RootView`), so an
    /// unguarded overlay would run reveal timers and answer menu commands for
    /// documents that aren't on screen.
    @Environment(\.isTabActive) private var isTabActive

    private var state: DocumentState { viewModel.state }
    private var viewer: ViewerViewModel { viewModel.viewer }
    private var pageCount: Int { viewModel.pageCount }

    /// Stays put while the pointer is on it, while it holds keyboard focus, and
    /// while a return point is pending — a control that vanishes mid-reach is
    /// worse than one that lingers.
    private var isPinned: Bool { isHovering || isEditing || viewer.returnPage != nil }

    /// Presentation mode has its own page indicator and hides the rest of the
    /// chrome; a second, interactive pill under it would be both redundant and
    /// unreachable.
    private var isActive: Bool { isTabActive && !state.isPresentationMode }

    private var isVisible: Bool { isActive && (isPinned || isRevealed) }

    var body: some View {
        VStack(spacing: 6) {
            if let origin = viewer.returnPage {
                returnChip(origin: origin)
            }
            pagePill
        }
        .padding(.bottom, 18)
        .opacity(isVisible ? 1 : 0)
        // Hidden means gone: a transparent pill must not swallow clicks aimed at
        // the page (or at a capture drag) underneath it.
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .animation(.easeOut(duration: 0.18), value: viewer.returnPage)
        .onHover { isHovering = $0 }
        .onChange(of: state.currentPageIndex) { _, _ in
            // Scrolling must never overwrite a number the reader is still typing.
            guard isActive, !isEditing else { return }
            reveal()
        }
        .onChange(of: isActive) { _, active in
            if !active, isEditing { cancelEditing() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfEditPageNumber)) { note in
            guard isActive, note.object as AnyObject? === viewModel else { return }
            beginEditing()
        }
        .task(id: revealToken) {
            guard revealToken > 0 else { return }
            try? await Task.sleep(for: .seconds(Self.lingerAfterPageChange))
            guard !Task.isCancelled else { return }
            isRevealed = false
        }
    }

    // MARK: - Page pill

    private var pagePill: some View {
        HStack(spacing: 2) {
            stepper(systemImage: "chevron.up", tooltip: "Previous Page", delta: -1)
                .disabled(state.currentPageIndex <= 0)
                .opacity(state.currentPageIndex <= 0 ? 0.35 : 1)

            if let section = viewer.currentSectionLabel {
                // Section is enrichment, never the anchor: it is absent for most
                // scanned PDFs and only ever as good as the embedded outline, so
                // it truncates away first and the page reading always survives.
                Text(section)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .padding(.leading, 6)
                    .padding(.trailing, 2)
                    .accessibilityLabel("Section: \(section)")
            }

            pageReadout

            stepper(systemImage: "chevron.down", tooltip: "Next Page", delta: 1)
                .disabled(state.currentPageIndex >= pageCount - 1)
                .opacity(state.currentPageIndex >= pageCount - 1 ? 0.35 : 1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .overlay(Capsule(style: .continuous).stroke(OakStyle.Colors.border, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private var pageReadout: some View {
        if isEditing {
            HStack(spacing: 3) {
                TextField("", text: $draftPage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .focused($fieldFocused)
                    .frame(width: fieldWidth)
                    .onSubmit(commitEditing)
                    .onExitCommand(perform: cancelEditing)
                    .onChange(of: draftPage) { _, _ in invalidEntry = false }

                Text("/ \(pageCount)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
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
            Button(action: beginEditing) {
                Text("\(state.currentPageIndex + 1) / \(pageCount)")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    // An explicit control boundary. The read-only `URLLabel` can
                    // get away with bare text; a field you can type into cannot.
                    .background(
                        RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                            .fill(isHovering ? OakStyle.Colors.hoverBackground : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Page \(state.currentPageIndex + 1) of \(pageCount) — click to go to a page")
            .accessibilityLabel("Page \(state.currentPageIndex + 1) of \(pageCount)")
            .accessibilityHint("Activate to enter a page number")
        }
    }

    /// Wide enough for the largest page number the document can produce, so the
    /// pill doesn't resize under the pointer as digits are typed.
    private var fieldWidth: CGFloat {
        CGFloat(max(2, String(pageCount).count)) * 9 + 6
    }

    private func stepper(systemImage: String, tooltip: String, delta: Int) -> some View {
        OakToolButton(systemImage: systemImage, tooltip: tooltip) {
            viewer.goToPage(state.currentPageIndex + delta)
        }
    }

    // MARK: - Return chip

    /// Named destination beats an unexplained chevron: "Back to p. 18" says where
    /// it goes, and it only exists when there is somewhere to go back to.
    private func returnChip(origin: Int) -> some View {
        Button {
            viewer.jumpBack()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
                Text("Back to p. \(origin + 1)")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            )
            .overlay(Capsule(style: .continuous).stroke(OakStyle.Colors.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Return to page \(origin + 1), where you jumped from")
        .accessibilityLabel("Back to page \(origin + 1)")
    }

    // MARK: - Editing

    private func beginEditing() {
        draftPage = "\(state.currentPageIndex + 1)"
        invalidEntry = false
        isEditing = true
        reveal()
        fieldFocused = true
        // Select the whole number so typing replaces it outright rather than
        // appending to it. The field editor only exists once focus has actually
        // landed, which is a runloop turn or two after `fieldFocused = true` —
        // selecting in the same hop silently does nothing.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard isEditing else { return }
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func commitEditing() {
        guard let entered = Int(draftPage.trimmingCharacters(in: .whitespaces)),
              entered >= 1, entered <= pageCount else {
            // Stay editable rather than silently discarding — the border and the
            // tooltip carry the valid range.
            invalidEntry = true
            fieldFocused = true
            return
        }
        viewer.goToPage(entered - 1, kind: .jump)
        endEditing()
    }

    private func cancelEditing() {
        endEditing()
    }

    private func endEditing() {
        isEditing = false
        invalidEntry = false
        fieldFocused = false
        reveal()
        // Hand the keyboard back to the reader, or ↑/↓ stop paging.
        NotificationCenter.default.post(name: .pdfFocusReader, object: viewModel)
    }

    private func reveal() {
        isRevealed = true
        revealToken += 1
    }
}
