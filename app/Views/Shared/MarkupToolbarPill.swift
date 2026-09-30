import SwiftUI
import AppKit

/// Preview-style split markup control, shared by the PDF and web toolbars: the
/// left half arms the tool and stays lit while armed, the right half opens the
/// colour and kind menu.
///
/// **Arming is the point.** A one-shot button acts on whatever is already
/// selected, so marking up a document means select → reach → click, once per
/// passage. Armed, the reader drags across text and the markup lands when the
/// selection settles, which is how every reader they already use behaves.
///
/// Both viewers drive the *same* state — `state.editorMode == .annotate` plus
/// `annotation.currentTool` — so this is one component rather than two that
/// look alike. Only the applier differs: `PDFViewCoordinator` marks up a
/// `PDFSelection` on mouse-up, `WebViewCoordinator` dispatches to the
/// OakHighlighter JS bridge when the DOM selection arrives.
///
/// `kinds` differs too, and deliberately: the PDF overlay can draw
/// strikethrough, the web highlighter's CSS only does highlight and underline.
/// Offering a kind the viewer cannot render would be a button that silently
/// does nothing.
struct MarkupToolbarPill: View {
    let viewModel: DocumentViewModel
    /// Markup kinds this viewer can actually render, in menu order.
    let kinds: [AnnotationTool]

    /// The kind to re-arm with, remembered across disarms so a reader working in
    /// underline gets underline back.
    @State private var lastTool: AnnotationTool

    init(viewModel: DocumentViewModel, kinds: [AnnotationTool] = [.highlight, .underline, .strikethrough]) {
        self.viewModel = viewModel
        self.kinds = kinds
        _lastTool = State(initialValue: kinds.first ?? .highlight)
    }

    private var state: DocumentState { viewModel.state }
    private var annotation: AnnotationViewModel { viewModel.annotation }

    private var armedTool: AnnotationTool {
        annotation.currentTool == .none ? lastTool : annotation.currentTool
    }

    private var isArmed: Bool {
        state.editorMode == .annotate && annotation.currentTool != .none
    }

    var body: some View {
        ToolbarPill {
            HStack(spacing: 0) {
                // No ink swatch under the glyph: the filled capsule already says
                // armed, the menu checkmarks the colour, and the first mark shows
                // it outright — three tells for one piece of state, in a 28pt
                // button.
                Button(action: toggle) {
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
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(isArmed
                      ? "\(armedTool.label) armed — drag across text to mark it. Escape to stop."
                      : "\(armedTool.label) — click to arm, then drag across text")
                .accessibilityLabel(isArmed ? "\(armedTool.label) armed" : "Arm \(armedTool.label)")

                Menu {
                    Picker("Colour", selection: colorBinding) {
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

                    if kinds.count > 1 {
                        Divider()
                        Picker("Style", selection: kindBinding) {
                            ForEach(kinds) { kind in
                                Label(kind.label, systemImage: kind.systemImage).tag(kind)
                            }
                        }
                        .pickerStyle(.inline)
                    }
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

    // MARK: - Arming

    private func toggle() {
        if isArmed {
            annotation.currentTool = .none
            viewModel.setEditorMode(.viewer)
        } else {
            arm(lastTool)
        }
    }

    private func arm(_ tool: AnnotationTool) {
        lastTool = tool
        annotation.currentTool = tool
        viewModel.setEditorMode(.annotate)
    }

    private var colorBinding: Binding<String> {
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
                if !isArmed { arm(lastTool) }
            }
        )
    }

    private var kindBinding: Binding<AnnotationTool> {
        Binding(get: { armedTool }, set: { arm($0) })
    }

    // MARK: - Swatch drawing

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
}
