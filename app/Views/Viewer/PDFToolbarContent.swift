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

    /// The markup kind to re-arm with, remembered across disarms so a reader who
    /// works in underline gets underline back.
    @State private var lastMarkupTool: AnnotationTool = .highlight

    private var state: DocumentState { viewModel.state }
    private var viewer: ViewerViewModel { viewModel.viewer }
    private var annotation: AnnotationViewModel { viewModel.annotation }
    private var pageCount: Int { viewModel.pageCount }

    var body: some View {
        HStack(spacing: 8) {
            pageNavPill
            locationLabel
                .frame(maxWidth: .infinity, alignment: .leading)
            if let origin = viewer.returnPage {
                returnChip(origin: origin)
            }
            zoomPill
            markupPill
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

    // MARK: - Markup

    /// Preview's split markup control: the left half arms the tool and stays lit
    /// while armed, the right half opens the colour/kind menu.
    ///
    /// Arming is the point. A one-shot button acts on whatever is already
    /// selected, so marking up a page means select → reach → click, once per
    /// passage. Armed, the reader drags across text and the markup lands on
    /// mouse-up, which is how every PDF reader they already use behaves. The
    /// machinery was here the whole time — `editorMode == .annotate` +
    /// `annotation.currentTool`, applied in `PDFViewCoordinator`, with Escape as
    /// the fast exit — it just had no control reaching it after the old toolbar
    /// was deleted.
    ///
    /// This does not replace the selection popup's highlight button. That one
    /// serves a different moment: text selected to read, copy or send to chat,
    /// which the reader *then* decides to keep. Arming for that would mean
    /// deselect → arm → re-drag the same words.
    private var markupPill: some View {
        ToolbarPill {
            HStack(spacing: 0) {
                Button(action: toggleMarkup) {
                    Image(systemName: armedTool.systemImage)
                        .font(.system(size: OakStyle.Font.icon))
                        .foregroundStyle(isArmed
                                         ? Color(nsColor: .labelColor)
                                         : Color(nsColor: .secondaryLabelColor))
                        .frame(width: 28, height: 28)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isArmed ? Color.primary.opacity(0.14) : .clear)
                        )
                        .overlay(alignment: .bottom) {
                            // The armed colour, shown under the glyph the way a
                            // real highlighter shows its ink.
                            if isArmed {
                                Capsule()
                                    .fill(Color(nsColor: annotation.strokeColor))
                                    .frame(width: 14, height: 2.5)
                                    .padding(.bottom, 4)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(isArmed
                      ? "\(armedTool.label) armed — drag across text to mark it. Escape to stop."
                      : "\(armedTool.label) — click to arm, then drag across text")
                .accessibilityLabel(isArmed ? "\(armedTool.label) armed" : "Arm \(armedTool.label)")

                Menu {
                    Picker("Colour", selection: markupColor) {
                        ForEach(OakStyle.AnnotationColors.highlightColors, id: \.name) { swatch in
                            Label {
                                Text(swatch.name)
                            } icon: {
                                // A non-template NSImage, not `Image(systemName:)`
                                // tinted with `.foregroundStyle`: AppKit renders
                                // SwiftUI menu icons as templates, which flattened
                                // every swatch to the same black dot.
                                Image(nsImage: Self.swatchImage(swatch.nsColor))
                            }
                            .tag(swatch.name)
                        }
                    }
                    .pickerStyle(.inline)

                    Divider()

                    Picker("Style", selection: markupKind) {
                        Label("Highlight", systemImage: "highlighter").tag(AnnotationTool.highlight)
                        Label("Underline", systemImage: "underline").tag(AnnotationTool.underline)
                        Label("Strikethrough", systemImage: "strikethrough").tag(AnnotationTool.strikethrough)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help("Markup colour and style")
                .accessibilityLabel("Markup colour and style")
            }
        }
    }

    // MARK: - Markup state

    private var armedTool: AnnotationTool {
        annotation.currentTool == .none ? lastMarkupTool : annotation.currentTool
    }

    private var isArmed: Bool {
        state.editorMode == .annotate && annotation.currentTool != .none
    }

    private func toggleMarkup() {
        if isArmed {
            annotation.currentTool = .none
            viewModel.setEditorMode(.viewer)
        } else {
            armMarkup(lastMarkupTool)
        }
    }

    private func armMarkup(_ tool: AnnotationTool) {
        lastMarkupTool = tool
        annotation.currentTool = tool
        viewModel.setEditorMode(.annotate)
    }

    private var markupColor: Binding<String> {
        Binding(
            get: {
                OakStyle.AnnotationColors.highlightColors
                    .first { Self.sameSwatch($0.nsColor, annotation.strokeColor) }?.name
                    ?? OakStyle.AnnotationColors.highlightColors[0].name
            },
            set: { name in
                guard let swatch = OakStyle.AnnotationColors.highlightColors
                    .first(where: { $0.name == name }) else { return }
                annotation.strokeColor = swatch.nsColor
                // Picking a colour is a statement of intent to mark something up.
                if !isArmed { armMarkup(lastMarkupTool) }
            }
        )
    }

    private var markupKind: Binding<AnnotationTool> {
        Binding(get: { armedTool }, set: { armMarkup($0) })
    }

    /// A filled circle in the swatch's own colour, flagged non-template so the
    /// menu draws it as drawn rather than recolouring it as a symbol.
    private static func swatchImage(_ color: NSColor, diameter: CGFloat = 12) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `strokeColor` carries the markup's alpha, and catalogue colours resolve
    /// per appearance, so identity comparison would never match a swatch.
    /// Compare RGB in a fixed space with a tolerance.
    private static func sameSwatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let tolerance: CGFloat = 0.02
        return abs(x.redComponent - y.redComponent) < tolerance
            && abs(x.greenComponent - y.greenComponent) < tolerance
            && abs(x.blueComponent - y.blueComponent) < tolerance
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
